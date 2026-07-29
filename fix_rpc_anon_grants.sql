-- ================================================================
-- 既存 RPC から anon の EXECUTE を剥奪する
--
--   対象:
--     public.get_mention_candidates(text)   … SECURITY DEFINER
--     public.get_my_role()                  … SECURITY INVOKER
--
--   背景:
--     add_notification_rpcs.sql の STEP 4 ④ 診断で、この2本が
--     anon から実行可能と判明した。原因は Supabase の初期設定
--
--       ALTER DEFAULT PRIVILEGES IN SCHEMA public
--         GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
--
--     により public スキーマの関数に anon への「明示的な」EXECUTE が
--     付与されること。REVOKE ... FROM public は PUBLIC 疑似ロール経由の
--     「暗黙の」権限しか剥がさないため、anon には届かない。
--
--   ★ 実測済み: 実害は無い（危険度「低」で確定）
--
--     check_get_mention_candidates.sql の STEP A〜E を実行した結果:
--
--       - SQL 内シミュレーション（STEP B-1 / B-2）… 0 行
--       - 本番 HTTP 実測（STEP E、publishable key で
--         POST /rest/v1/rpc/get_mention_candidates）… [] （空配列）
--       - 疎通確認（同 get_my_role）… null が返り、経路は生きていた
--
--     → 未ログインの第三者が氏名・会社名を読み出すことはできない。
--
--   では何のためにこのファイルを実行するのか:
--
--     get_mention_candidates が anon で 0 行になるのは、authorized CTE の
--     CASE が「どの WHEN にも該当せず ELSE false に落ちる」という
--     三値論理の帰結であって、「未認証を弾く」という明示的な意図では無い。
--     auth.uid() IS NULL の明示チェックは存在しない。
--
--     つまり今は閉じているが、CASE に条件が1つ足された時や
--     get_my_role() の実装が変わった時に、静かに開く構造になっている。
--     SECURITY DEFINER で氏名を返す関数を、そういう状態で
--     anon に開けたままにしておく理由が無い。
--
--     これは実害への対処ではなく、多層防御としての保険である。
--
--   ★ このファイルはまだ実行しないこと。
--     レビュー後、STEP ごとに区切って実行する想定。
--
--   使い方:
--     cat fix_rpc_anon_grants.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================


-- ================================================================
-- 【設計判断】get_my_role() の剥奪には副作用の可能性がある
-- ================================================================
--   get_mention_candidates は独立した RPC なので、anon から
--   剥奪しても影響は「anon が呼べなくなる」だけで完結する。
--
--   get_my_role() は事情が違う。この関数は RLS ポリシーの
--   【内側】から呼ばれている:
--
--     fix_rls_policies_comprehensive.sql
--       orders     : admins_read_all_orders / admins_update_orders / admins_insert_orders
--       schedules  : admins_read_all_schedules / admins_update_schedules / insert_schedules_for_own_orders
--       messages   : admins_read_all_messages / users_insert_own_messages / messages_update
--       sites ほか多数
--
--   RLS ポリシー式は【呼び出し元の権限】で評価される。
--   したがって anon から EXECUTE を剥奪すると、anon がこれらの
--   テーブルを引いたときに「0 行」ではなく
--
--     ERROR: permission denied for function get_my_role
--
--   で落ちるようになる。挙動が変わる。
--
--   ── 未ログイン状態でテーブルを引く箇所はあるか ──────────
--
--   index.html を調査した結果、未ログインで発行される
--   テーブルクエリは1箇所だけ:
--
--     index.html:1071  新規登録画面の企業ID照合（handleCheck）
--       sb.from('companies').select('name, is_active').eq('id', ...)
--       → signUp（index.html:1321）より前に実行されるため anon
--
--   companies の SELECT ポリシー（add_company_is_active.sql:14-21）は
--
--     read_active_companies      : USING (is_active = true)
--     admins_read_all_companies  : USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
--
--   のとおり auth.jwt() を【直接】参照しており、get_my_role() を
--   経由していない。したがって剥奪しても新規登録は壊れない見込み。
--
--   ── ただし「見込み」で実行しない ────────────────────────
--
--   STEP 1 でトランザクション内に REVOKE を適用し、anon として
--   実際に登録フローのクエリを流してから ROLLBACK する。
--   本番に何も残さずに副作用の有無を実測できる。
--
--   ── 剥奪後の性質 ────────────────────────────────────────
--
--   将来 anon から orders 等を引く実装が入った場合、
--   「0 行が返る」ではなく「エラーで落ちる」ようになる。
--   これは fail-closed であり、静かに空を返すより望ましい。
--   ただし挙動の変化として認識しておくこと。
--
--   なお get_my_role() 自体は呼び出し元自身の JWT から role を
--   読むだけで、anon が呼んでも null しか返らない（STEP E で実測済み）。
--   情報漏洩は元々存在しない。これも純粋に保険。


-- ================================================================
-- STEP 0 : 現状確認（読み取り専用）
-- ================================================================
--   これ1本だけを選択して実行する。
-- ----------------------------------------------------------------
SELECT * FROM (

  -- ① 対象2本の現在の権限
  SELECT 1 AS sec, '① 対象関数の現在の権限' AS section,
         (f.fname || ' → ' || g.grantee)::text AS item,
         CASE WHEN has_function_privilege(g.grantee, f.sig, 'EXECUTE')
              THEN '★EXECUTE あり' ELSE 'なし' END::text AS value
  FROM   (VALUES
           ('get_mention_candidates', 'public.get_mention_candidates(text)'),
           ('get_my_role',            'public.get_my_role()')
         ) AS f(fname, sig)
  CROSS  JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS g(grantee)

  UNION ALL

  -- ② public スキーマの全関数のうち anon から実行できるもの
  --    今回の2本以外に取りこぼしが無いかを確認する
  SELECT 2, '② anon 実行可能な public 関数の全件',
         (p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
          || CASE WHEN p.prosecdef THEN ' [DEFINER]' ELSE ' [INVOKER]' END)::text,
         '★anon 実行可'::text
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.prokind = 'f'
    AND  has_function_privilege('anon', p.oid, 'EXECUTE')

) AS r
ORDER BY sec, item;

-- ----------------------------------------------------------------
-- 【STEP 0 の判定】
--   ① get_mention_candidates / get_my_role とも anon に
--      「★EXECUTE あり」が出るはず（これから剥がす対象）
--      authenticated / service_role は「★EXECUTE あり」のまま維持する
--
--   ② ここに mark_message_read / mark_change_log_read が出ないこと
--      （2026-07-29 に剥奪済み）
--      ②に想定外の関数が並んだ場合は、このファイルの対象を
--      広げるかどうかを判断してから STEP 2 に進む
-- ----------------------------------------------------------------


-- ================================================================
-- STEP 1 : 【ドライラン】副作用の実測（本番に何も残さない）
-- ================================================================
--   REVOKE をトランザクション内で適用し、anon として
--   新規登録フローのクエリを実際に流してから ROLLBACK する。
--
--   ★ ROLLBACK で権限は完全に元に戻る。DDL/DCL もトランザクション対象。
--   ★ この STEP を丸ごと選択して実行すること。
-- ----------------------------------------------------------------
BEGIN;

  -- 本番と同じ REVOKE をトランザクション内で先に当てる
  REVOKE ALL ON FUNCTION public.get_mention_candidates(text) FROM PUBLIC, anon;
  REVOKE ALL ON FUNCTION public.get_my_role()                FROM PUBLIC, anon;

  -- 未ログイン状態を再現
  SELECT set_config('request.jwt.claims', '', true);
  SET LOCAL ROLE anon;

  -- ① 新規登録の企業ID照合（index.html:1071）が通ること ← 最重要
  --    ここが落ちると新規ユーザーが登録できなくなる
  SELECT
    'ドライラン: REVOKE 適用後の anon'::text AS 状態,
    current_user::text                       AS 実行ロール,
    (SELECT count(*) FROM public.companies WHERE is_active = true)::text
                                             AS 登録フローの企業ID照合;

ROLLBACK;

-- ----------------------------------------------------------------
-- 【STEP 1 の判定】
--   実行ロール = anon
--   登録フローの企業ID照合 = 有効な企業の件数（エラーにならないこと）
--
--   → 数値が返れば、剥奪しても新規登録は壊れない。STEP 2 へ進む。
--
--   ★ ERROR: permission denied for function get_my_role が出た場合
--     companies のポリシーが調査時と変わっている。
--     get_my_role() の剥奪は中止し、get_mention_candidates だけを
--     剥奪する（STEP 2 の該当行をコメントアウトする）。
--
--   ROLLBACK 済みなので、この STEP を実行しても本番の権限は変わらない。
-- ----------------------------------------------------------------


-- ================================================================
-- STEP 2 : 本番適用
-- ================================================================
--   grantee を明示列挙する。PUBLIC だけでは anon に届かない
--   （ファイル冒頭の背景を参照）。
--
--   GRANT を必ずセットで書く理由:
--     REVOKE ALL は authenticated 向けの権限も含めて剥がす対象に
--     なり得るため、剥がしたあと必要な相手に付け直すまでを
--     1つの手順にしておく。片方だけ実行して離席すると、
--     ログイン中のユーザーがメンション候補を引けなくなる。
--
--   service_role / postgres は剥がさない:
--     service_role はサーバー側の信頼済みロール。
--     ここを絞ると将来のバッチ処理から呼べなくなる。
--
--   ★ 冪等: REVOKE は権限が無い相手にも成功する。再実行して安全。
-- ----------------------------------------------------------------
REVOKE ALL     ON FUNCTION public.get_mention_candidates(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_mention_candidates(text) TO   authenticated;

REVOKE ALL     ON FUNCTION public.get_my_role()                FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_my_role()                TO   authenticated;


-- ================================================================
-- STEP 3 : アサーション（想定と違えば例外を投げて中断する）
-- ================================================================
--   前回 add_notification_rpcs.sql で「成功したように見えて
--   権限が残る」が実際に起きた。目視に頼らず機械的に検証する。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_anon_mc  boolean;
  v_anon_gr  boolean;
  v_auth_mc  boolean;
  v_auth_gr  boolean;
BEGIN
  v_anon_mc := has_function_privilege('anon',
                 'public.get_mention_candidates(text)', 'EXECUTE');
  v_anon_gr := has_function_privilege('anon',
                 'public.get_my_role()',                'EXECUTE');
  v_auth_mc := has_function_privilege('authenticated',
                 'public.get_mention_candidates(text)', 'EXECUTE');
  v_auth_gr := has_function_privilege('authenticated',
                 'public.get_my_role()',                'EXECUTE');

  IF v_anon_mc OR v_anon_gr THEN
    RAISE EXCEPTION
      'anon に EXECUTE が残っています（get_mention_candidates=% / get_my_role=%）。',
      v_anon_mc, v_anon_gr;
  END IF;

  IF NOT (v_auth_mc AND v_auth_gr) THEN
    RAISE EXCEPTION
      'authenticated に EXECUTE がありません（get_mention_candidates=% / get_my_role=%）。'
      '剥がしすぎです。GRANT を実行してください。', v_auth_mc, v_auth_gr;
  END IF;

  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE '権限チェック OK';
  RAISE NOTICE '  anon          : 両関数とも EXECUTE なし';
  RAISE NOTICE '  authenticated : 両関数とも EXECUTE あり';
  RAISE NOTICE '─────────────────────────────────────';
END $$;


-- ================================================================
-- STEP 4 : 確認用 SELECT
-- ================================================================
SELECT * FROM (

  -- ① 対象2本の最終状態
  SELECT 1 AS sec, '① 対象関数の権限（適用後）' AS section,
         (f.fname || ' → ' || g.grantee)::text AS item,
         CASE WHEN has_function_privilege(g.grantee, f.sig, 'EXECUTE')
              THEN 'EXECUTE あり' ELSE '—' END::text AS value
  FROM   (VALUES
           ('get_mention_candidates', 'public.get_mention_candidates(text)'),
           ('get_my_role',            'public.get_my_role()')
         ) AS f(fname, sig)
  CROSS  JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS g(grantee)

  UNION ALL

  -- ② anon から実行できる public 関数が残っていないか（全件）
  SELECT 2, '② anon 実行可能な public 関数の残り',
         (p.proname || '(' || pg_get_function_arguments(p.oid) || ')')::text,
         '★まだ残っている'::text
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.prokind = 'f'
    AND  has_function_privilege('anon', p.oid, 'EXECUTE')

  UNION ALL

  -- ③ ②が0件だと行が消えて分かりにくいので件数も出す
  SELECT 3, '③ 件数', 'anon 実行可能な public 関数の総数',
         (SELECT count(*)::text
          FROM   pg_proc p
          JOIN   pg_namespace n ON n.oid = p.pronamespace
          WHERE  n.nspname = 'public' AND p.prokind = 'f'
            AND  has_function_privilege('anon', p.oid, 'EXECUTE'))

) AS r
ORDER BY sec, item;


-- ================================================================
-- 実行後の判定
-- ================================================================
--   ① anon = 両関数とも「—」
--      authenticated = 両関数とも「EXECUTE あり」
--      service_role  = 両関数とも「EXECUTE あり」（意図的に維持）
--
--   ② 行が出ないこと（＝ anon 実行可能な関数が残っていない）
--
--   ③ 0 であること
--
--   ★ ②③に想定外の関数が残っていた場合は、それが何なのかを
--     確認してから対応を決める。Supabase の拡張機能が作る関数
--     （pgcrypto の gen_random_uuid など）は public に置かれていれば
--     ここに出るが、引数から結果を生成するだけで DB を読まないため
--     剥奪の必要は無い。判断基準は「DB のデータを読む関数かどうか」。
--
-- ================================================================
-- 実行後の動作確認（本番 HTTP・任意）
-- ================================================================
--   check_get_mention_candidates.sql STEP E と同じ手順で、
--   今度は permission denied になることを確認する。
--
--     cd ~/Documents/hacchu-kanri
--     ANON=$(grep -oE 'sb_publishable_[A-Za-z0-9_-]+' index.html | head -1)
--     SUPA_URL=$(grep -oE 'https://[a-z0-9]+\.supabase\.co' index.html | head -1)
--
--     curl -s -X POST "$SUPA_URL/rest/v1/rpc/get_mention_candidates" \
--       -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
--       -H "Content-Type: application/json" \
--       -d '{"p_order_id":"<実在の案件番号>"}'
--
--     期待: {"code":"42501", ... "permission denied for function get_mention_candidates"}
--       → 剥奪前の [] から変わっていれば、確かに閉じたことの証明になる。
--
--     unset ANON SUPA_URL
--
--   ★ ログイン中のアプリ側で、チャットのメンション候補ピッカー
--     （index.html:5220 / 6822 / 7431 が get_mention_candidates を呼ぶ）が
--     従来どおり候補を出すことも確認すること。
--     authenticated には EXECUTE を残しているので変化しないはずだが、
--     権限をいじった直後なので実際に開いて確かめる。
-- ================================================================
