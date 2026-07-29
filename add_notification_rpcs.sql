-- ================================================================
-- Phase 1 : 通知の個別既読 RPC 2本
--
--   計画書: docs/notification-bell-plan.md §2-5
--
--   目的:
--     通知ベルの1件をクリックしたとき、その1件だけを
--     「自分にとって既読」にする。read_by 配列に自分の UUID を追記する。
--
--       mark_message_read(bigint)    … messages 1件
--       mark_change_log_read(uuid)   … order_change_logs 1件
--
--   ★ 前提（先に実行済みであること）:
--     add_order_change_logs_read_by.sql（STEP 0/1/2 まで実行済み・2026-07-29 完了）
--     未実行の場合は STEP 0 で例外を投げて中断する。
--
--   ★ このファイルはまだ実行しないこと。
--     レビュー後、STEP ごとに区切って実行する想定。
--
--   使い方:
--     cat add_notification_rpcs.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
-- ================================================================


-- ================================================================
-- 【設計判断①】なぜ RPC にするのか — read-modify-write の置き換え
-- ================================================================
--   現行の markChatRead()（index.html:10511-10532）は
--
--     ① SELECT id, read_by  で未読行を取ってくる
--     ② JS で [...read_by, uid] を組み立てる
--     ③ 行ごとに UPDATE を Promise.all で並列発行
--
--   という read-modify-write。これには2つの問題がある。
--
--     (a) lost update
--         ① と ③ の間に他クライアントが read_by を書き換えると、
--         JS が持っている古い配列で丸ごと上書きしてしまい、
--         その間に入った既読が消える。3秒ポーリングで
--         複数タブ・複数端末が同時に動く本システムでは現実に起こる。
--
--     (b) N 行 = N リクエスト
--         計画書 §7-3 のとおり、個別既読は1リクエストで済ませたい。
--
--   RPC 側で `array_append(read_by, uid)` を1本の UPDATE として実行すれば、
--   PostgreSQL の行ロックにより (a) は原理的に発生しない。
--   READ COMMITTED では後続の UPDATE は先行トランザクションの
--   コミットを待ってから WHERE を再評価し、更新後の read_by を読み直すため、
--   追記が消えることはない。
--
--   → 「RPC にする理由」は権限の話ではなく、まず原子性の話である。
--     この区別が次の②につながる。


-- ================================================================
-- 【設計判断②】SECURITY DEFINER の要否 — 2本で結論が異なる
-- ================================================================
--   計画書 §2-5 では2本とも SECURITY DEFINER で書いていたが、
--   実際の RLS ポリシーとクライアントの取得条件を確認した結果、
--   messages 側は DEFINER が不要と判断した。
--
--   ────────────────────────────────────────────────
--   mark_message_read  →  SECURITY INVOKER（デフォルト）
--   ────────────────────────────────────────────────
--     messages の UPDATE ポリシー "messages_update"
--     （fix_rls_policies_comprehensive.sql:158-175）は
--
--       自分の注文（orders.user_id = auth.uid()）
--       OR get_my_role() IN ('admin','manager','staff')
--
--     を許可している。
--
--     そして顧客側の fetchOrders は .eq('user_id', user.id)
--     （index.html:5732 / ポーリング側 5773）で自分の注文しか取らない。
--     つまり「通知に出る = クリックし得る」全員が、
--     既にそのメッセージへの UPDATE 権を持っている。
--
--     権限を広げる必要が無いなら DEFINER にすべきではない。
--     DEFINER にすると RLS が丸ごとバイパスされ、
--     「関数の中で認可を書き直す」責任が発生する。
--     書き直した認可がポリシーとズレた瞬間に穴になる。
--     INVOKER のままなら認可は RLS ポリシー1箇所に残り、
--     ポリシーを直せば RPC も自動的に追随する。
--
--     原子性（①）は DEFINER/INVOKER と無関係に、
--     UPDATE を1文にすることで得られる。
--
--   ────────────────────────────────────────────────
--   mark_change_log_read  →  SECURITY DEFINER（必須）
--   ────────────────────────────────────────────────
--     order_change_logs の UPDATE ポリシー
--     "order_change_logs_admin_update"（add_order_change_logs.sql:35-38）は
--     admin/manager だけを許可している。
--
--     しかし通知ベルは staff も使う（計画書 §0 のゴール5・管理者側は
--     admin/manager/staff の3ロールが AdminApp を開く）。
--     staff が変更通知をクリックしても既読が打てないと、
--     バッジが永久に消えない。
--
--     ここで UPDATE ポリシーを staff に広げると、
--     confirmed_by / confirmed_at（＝業務上の確認、既存 UI の表示根拠
--     index.html:8472-8500）まで staff が書き換えられるようになる。
--     計画書 §2-2 で read_by と confirmed_by の意味を分離した前提が崩れる。
--
--     → ポリシーは広げず、DEFINER の RPC 1本だけを穴として開ける。
--       この関数は read_by しか触らないので、
--       confirmed_by は誰にも書き換えられないまま保たれる。
--
--     DEFINER である以上、認可は関数内で明示的に書く（後述の p_log_id 側）。
--     認可述語は get_mention_candidates（add_mention_candidates_rpc.sql:77-93）と
--     同じ形にしてある。


-- ================================================================
-- STEP 0 : 事前アサーション（想定と違えば例外を投げて中断する）
-- ================================================================
--   RPC は CREATE OR REPLACE で作られるため、前提が崩れていても
--   「作れてしまう」。壊れた前提の上に関数を置くと、
--   Phase 2 でクライアントを繋いだときに初めて気づくことになる。
--   ここで機械的に止める。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_msg_id_type   text;
  v_log_id_type   text;
  v_msg_readby    text;
  v_log_readby    text;
  v_has_role_fn   boolean;
  v_msg_rls       boolean;
  v_msg_upd_pol   int;
BEGIN
  -- ① messages.id の型（RPC の引数型と一致していること）
  SELECT data_type INTO v_msg_id_type
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='messages' AND column_name='id';

  IF v_msg_id_type IS NULL THEN
    RAISE EXCEPTION 'public.messages.id が見つかりません。';
  END IF;
  IF v_msg_id_type <> 'bigint' THEN
    RAISE EXCEPTION
      'messages.id が bigint ではありません（実際=%）。'
      'mark_message_read の引数型 p_message_id bigint を'
      '実際の型に合わせてから実行してください。', v_msg_id_type;
  END IF;

  -- ② order_change_logs.id の型
  SELECT data_type INTO v_log_id_type
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='order_change_logs' AND column_name='id';

  IF v_log_id_type <> 'uuid' THEN
    RAISE EXCEPTION
      'order_change_logs.id が uuid ではありません（実際=%）。', COALESCE(v_log_id_type,'(列なし)');
  END IF;

  -- ③ read_by 列が両テーブルに存在し、text[] であること
  SELECT udt_name INTO v_msg_readby
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='messages' AND column_name='read_by';

  SELECT udt_name INTO v_log_readby
  FROM   information_schema.columns
  WHERE  table_schema='public' AND table_name='order_change_logs' AND column_name='read_by';

  IF v_msg_readby IS DISTINCT FROM '_text' THEN
    RAISE EXCEPTION
      'messages.read_by が text[] ではありません（実際=%）。', COALESCE(v_msg_readby,'(列なし)');
  END IF;

  IF v_log_readby IS DISTINCT FROM '_text' THEN
    RAISE EXCEPTION
      'order_change_logs.read_by が text[] ではありません（実際=%）。'
      '先に add_order_change_logs_read_by.sql の STEP 1 を実行してください。',
      COALESCE(v_log_readby,'(列なし)');
  END IF;

  -- ④ get_my_role() が存在すること（mark_change_log_read の認可で使う）
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN   pg_namespace n ON n.oid = p.pronamespace
    WHERE  p.proname = 'get_my_role' AND n.nspname = 'public'
  ) INTO v_has_role_fn;

  IF NOT v_has_role_fn THEN
    RAISE EXCEPTION
      'public.get_my_role() が存在しません。'
      '先に fix_rls_policies_comprehensive.sql を実行してください。';
  END IF;

  -- ⑤ messages の RLS が有効で、UPDATE ポリシーが存在すること
  --    mark_message_read は INVOKER なので、認可をこのポリシーに委ねている。
  --    ポリシーが消えていると「誰も既読を打てない」または
  --    「RLS 無効で誰でも打てる」のどちらかになる。前提として検証する。
  SELECT relrowsecurity INTO v_msg_rls
  FROM   pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE  n.nspname='public' AND c.relname='messages';

  IF NOT COALESCE(v_msg_rls, false) THEN
    RAISE EXCEPTION
      'public.messages の RLS が無効です。'
      'mark_message_read は SECURITY INVOKER で RLS に認可を委ねているため、'
      'RLS 無効のままでは認可が効きません。';
  END IF;

  SELECT count(*) INTO v_msg_upd_pol
  FROM   pg_policies
  WHERE  schemaname='public' AND tablename='messages'
    AND  cmd IN ('UPDATE', 'ALL');

  IF v_msg_upd_pol = 0 THEN
    RAISE EXCEPTION
      'public.messages に UPDATE を許可するポリシーがありません。'
      'このまま mark_message_read を作ると、誰も既読を打てません。'
      'fix_rls_policies_comprehensive.sql の "messages_update" を確認してください。';
  END IF;

  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE '事前チェック OK';
  RAISE NOTICE '  messages.id                : %', v_msg_id_type;
  RAISE NOTICE '  order_change_logs.id       : %', v_log_id_type;
  RAISE NOTICE '  messages.read_by           : text[]';
  RAISE NOTICE '  order_change_logs.read_by  : text[]';
  RAISE NOTICE '  get_my_role()              : あり';
  RAISE NOTICE '  messages RLS               : 有効 / UPDATE ポリシー %件', v_msg_upd_pol;
  RAISE NOTICE '─────────────────────────────────────';
END $$;


-- ================================================================
-- STEP 1 : mark_message_read(bigint)
-- ================================================================
--   messages 1件を、呼び出し元の既読にする。
--
--   SECURITY: INVOKER（明示しない = デフォルト）
--     → 認可は messages_update ポリシーに委ねる。設計判断②を参照。
--
--   戻り値: void
--     計画書 §4-1 のとおり markOneRead() は await しない
--     fire-and-forget 呼び出しであり、成否は PostgREST の
--     HTTP ステータス（例外なら 4xx/5xx）で判定できる。
--     返す値が無いので、対象行が存在しなかった場合と
--     既に既読だった場合は区別できないが、どちらも
--     クライアントの取るべき行動は同じ（何もしない）。
--
--     ※ 後から boolean 等に変えたくなった場合、
--       CREATE OR REPLACE では戻り値型を変更できない。
--       DROP FUNCTION public.mark_message_read(bigint); が先に必要。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_message_read(p_message_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  -- 未認証で呼ばれた場合は黙って無視せず、明示的に落とす。
  -- 黙って 0 行更新にすると、セッション切れが
  -- 「既読が付かない」という再現しにくい不具合として現れる。
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '認証されていません（auth.uid() が NULL）。';
  END IF;

  UPDATE public.messages
  SET    read_by = array_append(COALESCE(read_by, '{}'), v_uid::text)
  WHERE  id = p_message_id
    -- 既に自分が入っていれば何もしない（重複追記の防止・冪等）
    AND  NOT (v_uid::text = ANY(COALESCE(read_by, '{}')))
    -- 自分が送ったメッセージには自分を追記しない。
    --   read_by は「既読 N」表示の根拠にもなっている（index.html:6959-6960）。
    --   自分を入れると送信者が自分のメッセージの既読数に数えられる。
    --   既存の markChatRead も sender_id.neq.uid で同じ除外をしており
    --   （index.html:10523）、そこに揃える。
    --   なお計画書 §1-3 により自分の送信メッセージは
    --   そもそも未読フィードに載らないため、通常は到達しない防御。
    AND  sender_id IS DISTINCT FROM v_uid;
END;
$$;

COMMENT ON FUNCTION public.mark_message_read(bigint) IS
  '通知ベルの個別既読。messages 1件の read_by に auth.uid() を追記する。'
  'SECURITY INVOKER。認可は messages の RLS ポリシーに委ねている。';


-- ================================================================
-- STEP 2 : mark_change_log_read(uuid)
-- ================================================================
--   order_change_logs 1件を、呼び出し元の既読にする。
--
--   SECURITY: DEFINER（必須）
--     → order_change_logs の UPDATE ポリシーが admin/manager 限定で、
--       staff・顧客が既読を打てないため。設計判断②を参照。
--       ポリシーを広げると confirmed_by まで開いてしまう。
--
--   DEFINER は RLS を丸ごとバイパスするため、
--   認可をこの関数の中で明示的に書く。書かないと、
--   任意の authenticated ユーザーが log の uuid を総当たりして
--   他社案件の変更ログの read_by に自分を混入させられる。
--   （情報は漏れないが read_by が汚れ、Phase 5 で read_by を
--     監査用途に使いたくなったときに信用できないデータになる）
--
--   認可述語は get_mention_candidates の authorized CTE
--   （add_mention_candidates_rpc.sql:77-93）と同じ形。
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mark_change_log_read(p_log_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_role     text := get_my_role();
  v_order_id text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION '認証されていません（auth.uid() が NULL）。';
  END IF;

  -- 対象ログの order_id を取得（存在しなければ静かに終了）
  --   削除済みメッセージを指す通知と同じく、
  --   「対象が消えている」のは通常運用で起こり得る（計画書 §9）。
  --   例外にするとベルのクリックがエラーになるため、no-op で返す。
  SELECT order_id INTO v_order_id
  FROM   public.order_change_logs
  WHERE  id = p_log_id;

  IF v_order_id IS NULL THEN
    RETURN;
  END IF;

  -- 認可: 社内（admin/manager/staff）は無条件。
  --       顧客は自分の注文に紐づくログのみ。
  --       （顧客側 fetchOrders は .eq('user_id', auth.uid()) なので
  --         この条件が顧客に見えている範囲と一致する）
  IF v_role NOT IN ('admin', 'manager', 'staff') THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.orders o
      WHERE  o.id = v_order_id
        AND  o.user_id = v_uid
    ) THEN
      RAISE EXCEPTION
        'この変更ログを既読にする権限がありません（log_id=%）。', p_log_id;
    END IF;
  END IF;

  UPDATE public.order_change_logs
  SET    read_by = array_append(COALESCE(read_by, '{}'), v_uid::text)
  WHERE  id = p_log_id
    AND  NOT (v_uid::text = ANY(COALESCE(read_by, '{}')));

  -- ※ messages と違い changed_by の自己除外はしない。
  --   order_change_logs には「既読 N」表示が無く、read_by は
  --   純粋に未読判定にしか使われない。加えて 2026-07-29 の backfill で
  --   changed_by を read_by に投入済み（自分の変更は自分にとって既読）なので、
  --   自己除外を入れると backfill と規約が食い違う。
END;
$$;

COMMENT ON FUNCTION public.mark_change_log_read(uuid) IS
  '通知ベルの個別既読。order_change_logs 1件の read_by に auth.uid() を追記する。'
  'SECURITY DEFINER。UPDATE ポリシーを広げずに staff/顧客へ read_by だけを開けるため。'
  'confirmed_by は触らない。';


-- ================================================================
-- STEP 3 : 実行権限
-- ================================================================
--   SECURITY DEFINER 関数を PUBLIC / anon のまま置かないこと。
--   authenticated にだけ EXECUTE を残す。
--
-- ----------------------------------------------------------------
-- 【2026-07-29 修正】REVOKE ... FROM public だけでは anon が残る
-- ----------------------------------------------------------------
--   当初は add_mention_candidates_rpc.sql:131-132 に倣って
--
--     REVOKE ALL ON FUNCTION ... FROM public;
--
--   と書いていたが、実行後の確認で両関数とも anon に EXECUTE が
--   残っていた。原因は Supabase プロジェクトの初期設定に含まれる
--   デフォルト権限:
--
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public
--       GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
--
--   これにより public スキーマに関数を作った瞬間、anon に
--   「明示的な」EXECUTE 権が付与される。
--
--   一方 REVOKE ... FROM public が剥がすのは PUBLIC 疑似ロール経由の
--   「暗黙の」権限だけで、anon に直接付いた明示的な GRANT には届かない。
--   両者は別の権限であり、REVOKE が効かなかったのではなく
--   別のものを剥がしていた、というのが正確な理解。
--
--   → grantee を明示列挙する。PUBLIC と anon の両方を書く。
--     PUBLIC 側も残す理由: 将来 ALTER DEFAULT PRIVILEGES の設定が
--     変わって暗黙付与に戻った場合に、こちらが効く。
--     どちらが効いているかに依存しない書き方にしておく。
--
--   service_role / postgres は剥がさない。
--     service_role はサーバー側（Edge Function 等）の信頼済みロールで、
--     ここを絞ると将来 §12 のメール通知バッチから呼べなくなる。
--     postgres は所有者。
--
--   ★ 冪等性: REVOKE は権限が無い相手に対しても成功する（no-op）。
--     何度実行しても安全。
-- ----------------------------------------------------------------
REVOKE ALL     ON FUNCTION public.mark_message_read(bigint)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mark_message_read(bigint)  TO   authenticated;

REVOKE ALL     ON FUNCTION public.mark_change_log_read(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mark_change_log_read(uuid) TO   authenticated;


-- ================================================================
-- STEP 3.5 : 権限のアサーション（想定と違えば例外を投げて中断する）
-- ================================================================
--   STEP 3 は「成功したように見えて権限が残る」ことが実際に起きた。
--   目視の確認 SELECT だけに頼らず、機械的に検証して止める。
--
--   has_function_privilege() は PUBLIC 経由・ロール継承経由も
--   含めて実効的な権限を返すため、経路によらず判定できる。
-- ----------------------------------------------------------------
DO $$
DECLARE
  v_anon_msg  boolean;
  v_anon_log  boolean;
  v_auth_msg  boolean;
  v_auth_log  boolean;
BEGIN
  v_anon_msg := has_function_privilege('anon',
                  'public.mark_message_read(bigint)',  'EXECUTE');
  v_anon_log := has_function_privilege('anon',
                  'public.mark_change_log_read(uuid)', 'EXECUTE');
  v_auth_msg := has_function_privilege('authenticated',
                  'public.mark_message_read(bigint)',  'EXECUTE');
  v_auth_log := has_function_privilege('authenticated',
                  'public.mark_change_log_read(uuid)', 'EXECUTE');

  IF v_anon_msg OR v_anon_log THEN
    RAISE EXCEPTION
      'anon に EXECUTE が残っています（mark_message_read=% / mark_change_log_read=%）。'
      'REVOKE が効いていません。ALTER DEFAULT PRIVILEGES で他のロール経由の'
      '付与が無いか確認してください。', v_anon_msg, v_anon_log;
  END IF;

  IF NOT (v_auth_msg AND v_auth_log) THEN
    RAISE EXCEPTION
      'authenticated に EXECUTE がありません（mark_message_read=% / mark_change_log_read=%）。'
      'REVOKE で剥がしすぎています。GRANT を実行してください。',
      v_auth_msg, v_auth_log;
  END IF;

  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE '権限チェック OK';
  RAISE NOTICE '  anon          : 両関数とも EXECUTE なし';
  RAISE NOTICE '  authenticated : 両関数とも EXECUTE あり';
  RAISE NOTICE '─────────────────────────────────────';
END $$;


-- ================================================================
-- STEP 4 : 確認用 SELECT（実行後にこれだけを流す）
-- ================================================================
SELECT * FROM (

  -- ① 関数が作られたか / SECURITY 設定が意図どおりか
  SELECT 1 AS sec, '① 関数定義' AS section,
         p.proname::text AS item,
         format('security=%s / lang=%s / 引数=%s / 戻り=%s / search_path=%s',
                CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END,
                l.lanname,
                pg_get_function_arguments(p.oid),
                pg_get_function_result(p.oid),
                COALESCE(array_to_string(p.proconfig, ','), '(未設定)'))::text AS value
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  JOIN   pg_language  l ON l.oid = p.prolang
  WHERE  n.nspname = 'public'
    AND  p.proname IN ('mark_message_read', 'mark_change_log_read')

  UNION ALL

  -- ② 実行権限（anon に付いていないこと）
  --    information_schema.routine_privileges は PUBLIC 経由の権限や
  --    自分がメンバーでないロールの権限を取りこぼすため使わない。
  --    has_function_privilege() は経路によらず実効権限を返す。
  SELECT 2, '② 実行権限',
         (f.fname || ' → ' || g.grantee)::text,
         CASE WHEN has_function_privilege(g.grantee, f.sig, 'EXECUTE')
              THEN 'EXECUTE あり' ELSE '—' END::text
  FROM   (VALUES
           ('mark_message_read',    'public.mark_message_read(bigint)'),
           ('mark_change_log_read', 'public.mark_change_log_read(uuid)')
         ) AS f(fname, sig)
  CROSS  JOIN (VALUES ('anon'), ('authenticated'), ('service_role'))
         AS g(grantee)

  UNION ALL

  -- ③ 既読の現状（Phase 2 で動かす前のベースライン）
  SELECT 3, '③ 現状', 'messages 総行数',
         (SELECT count(*)::text FROM public.messages)
  UNION ALL
  SELECT 3, '③ 現状', 'order_change_logs 総行数',
         (SELECT count(*)::text FROM public.order_change_logs)
  UNION ALL
  SELECT 3, '③ 現状', 'order_change_logs read_by が空の行',
         (SELECT count(*)::text FROM public.order_change_logs
          WHERE array_length(read_by, 1) IS NULL)

  UNION ALL

  -- ④ 【診断・読み取り専用】既存 RPC の anon 実行権
  --    今回の原因（ALTER DEFAULT PRIVILEGES による anon への明示付与）は
  --    このプロジェクトで public スキーマに作った関数すべてに効いている。
  --    つまり過去に作った RPC も同じ状態のはず。
  --    本ファイルのスコープ外なので変更はしないが、実態を可視化しておく。
  SELECT 4, '④ 既存 RPC の anon 実行権（診断のみ・本ファイルでは変更しない）',
         (p.proname || '(' || pg_get_function_arguments(p.oid) || ')'
          || CASE WHEN p.prosecdef THEN ' [DEFINER]' ELSE ' [INVOKER]' END)::text,
         CASE WHEN has_function_privilege('anon', p.oid, 'EXECUTE')
              THEN '★anon 実行可' ELSE 'anon 不可' END::text
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  WHERE  n.nspname = 'public'
    AND  p.proname IN ('get_mention_candidates', 'mark_messages_read', 'get_my_role')

) AS r
ORDER BY sec, item;


-- ================================================================
-- 実行後の判定
-- ================================================================
--   ① 2行出ること
--        mark_message_read     : security=INVOKER / 引数=p_message_id bigint
--                                / 戻り=void / search_path=search_path=public, auth, pg_temp
--        mark_change_log_read  : security=DEFINER / 引数=p_log_id uuid
--                                / 戻り=void / search_path=同上
--      ★ mark_change_log_read が INVOKER になっていたら失敗。staff が既読を打てない。
--      ★ mark_message_read が DEFINER になっていたら失敗。RLS が効かなくなる。
--
--   ② 6行出ること。合格の形は:
--        anon          → 両関数とも「—」
--        authenticated → 両関数とも「EXECUTE あり」
--        service_role  → 両関数とも「EXECUTE あり」（意図的に残している）
--      ★ anon に「EXECUTE あり」が出たら失敗。ただし STEP 3.5 の
--        アサーションで先に例外が出るため、通常ここまで到達しない。
--
--   ③ order_change_logs read_by が空の行 = 0（2026-07-29 backfill 済みのため）
--
--   ④ 診断のみ。ここに「★anon 実行可」が出ても本ファイルの合否には影響しない。
--      別途 §「既知の課題」を参照。
--
-- ================================================================
-- 動作確認（任意・SQL Editor から）
-- ================================================================
--   SQL Editor は service_role で動くため auth.uid() が NULL になり、
--   両関数とも「認証されていません」で落ちる。これは正常な挙動であり、
--   NULL ガードが効いていることの確認になる。
--
--     SELECT public.mark_message_read(1);
--     → ERROR: 認証されていません（auth.uid() が NULL）。
--
--   実際の追記確認は Phase 2 でクライアントから繋いだあとに行う。
--   ブラウザの devtools から直接叩く場合:
--
--     await sb.rpc('mark_message_read',    { p_message_id: 123 })
--     await sb.rpc('mark_change_log_read', { p_log_id: '....-....' })
--
--   期待:
--     - 自分の UUID が read_by に1つだけ増える（2回叩いても増えない＝冪等）
--     - 自分が送ったメッセージには増えない
--     - order_change_logs 側は confirmed_by / confirmed_at が不変
--
-- ================================================================
-- 既知の課題（本ファイルのスコープ外・別タスクとして起票する）
-- ================================================================
--
-- ★0. 【解消済み】旧 RPC mark_messages_read(text, text)
--
--    email を read_by に入れる旧仕様の RPC（alter_messages_for_chat.sql:14-23）は
--    DROP 済みであることを 2026-07-29 の STEP 4 ④ 診断で確認した
--    （関数リストに現れなかった）。
--    read_by への UUID 以外の混入経路はこれで塞がっている。
--    計画書 §2-5 の「Phase 5 で削除候補」は対応済みとして扱う。
--
--
-- ★1. get_mention_candidates(text) が anon から実行可能【要調査】
--
--    2026-07-29 の STEP 4 ④ 診断で判明。
--
--      - SECURITY DEFINER（RLS を完全にバイパスする）
--      - add_mention_candidates_rpc.sql:131-132 は
--        REVOKE ALL ... FROM public を書いているが、
--        今回判明したとおりこれでは anon を剥がせない
--      - 引数が p_order_id text ＝ 案件番号を1つ指定して呼ぶ形
--      - orders.id は "B-2024-101" 形式（CLAUDE.md データ構造）で
--        連番を含むため、第三者による推測は容易
--
--    危険度は「この関数が何を返すか」で決まる:
--      RETURNS TABLE (id uuid, name text, kind text, company_name text)
--      ＝ 氏名と会社名を返す。個人情報に該当する。
--
--    ただし関数内の authorized CTE（同ファイル:77-93）が
--    get_my_role() と auth.uid() を参照しており、anon では
--    どちらも NULL になるため 0 行で返る「はず」である。
--
--    ★「はず」で済ませないこと。
--      SECURITY DEFINER + 個人情報 + 推測可能な引数 という
--      3つが揃っているため、実際に anon キーで叩いて
--      0 行が返ることを実測で確認する。
--      確認できるまでは未確認の穴として扱う。
--
--    対処（順序）:
--      (1) 実測: anon キーで rpc('get_mention_candidates',
--          { p_order_id: '実在する案件番号' }) を叩き、
--          返却行数と中身を確認する
--      (2) 権限剥奪: add_mention_candidates_rpc.sql:131 を
--          REVOKE ALL ... FROM PUBLIC, anon; に修正して再実行
--      (3) (1) で行が返っていた場合は、関数内の認可を
--          「auth.uid() IS NULL なら即 0 行」で明示的に閉じる
--
--    今日この場で対処しない理由: 本ファイルは「新規2本の追加」に
--    スコープを絞っており、既存関数の修正を混ぜると
--    ロールバック単位が曖昧になる。別ファイル・別コミットで扱う。
--
--
-- ★2. get_my_role() が anon から実行可能
--
--    同じく 2026-07-29 の診断で判明。
--    SECURITY INVOKER で、auth.jwt() -> 'app_metadata' ->> 'role' を
--    返すだけの関数（fix_rls_policies_comprehensive.sql:58-63）。
--    anon が呼んでも自分の JWT を見るだけで NULL が返るため、
--    他人の情報は取得できない。実害は無い。
--
--    ただし ★3 の作法を全関数に適用する際、
--    これも FROM PUBLIC, anon の対象に含める。
--
--
-- ★3. プロジェクト全体の作法として
--
--    public スキーマに RPC を追加するときは必ず
--      REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon;
--    を書く、というルールを CLAUDE.md に追記する（Phase 5）。
--
--    根治するなら ALTER DEFAULT PRIVILEGES 自体を変更する手もあるが、
--    Supabase の標準設定を書き換えると PostgREST のスキーマキャッシュや
--    他システム（Seed Note / MK Daily は同一 Supabase プロジェクトではないが
--    同じ作法で作られている）に影響が及ぶ可能性があるため、
--    関数ごとに明示 REVOKE する方針を採る。
--
--
-- ★4. read_by への UUID 以外の混入経路
--
--    ★1 の RPC が email を入れる唯一残った経路。削除すれば
--    書き込み口は本ファイルの2本 + markChatRead に閉じる。
--    計画書 §2-5 / §6 Phase 5 に記録済み。
-- ================================================================
