-- ================================================================
-- 調査: get_mention_candidates(text) の anon からの露出範囲
--
--   きっかけ:
--     add_notification_rpcs.sql の STEP 4 ④ 診断で、
--     get_mention_candidates が anon から実行可能と判明した。
--     SECURITY DEFINER は RLS を完全にバイパスするため、
--     関数内の認可だけが最後の砦になっている。
--
--   確認したいこと:
--     ① 何を返す関数か（個人情報の範囲）
--     ② anon で実行したとき、本当に 0 行なのか
--     ③ authorized CTE は anon を弾く設計になっているか
--
--   ★ このファイルは読み取り専用。DDL・DML は一切含まない。
--     ロール切替はすべて BEGIN 〜 ROLLBACK の中で行い、
--     トランザクション終了時に自動で元に戻る。
--
--   使い方:
--     cat check_get_mention_candidates.sql | pbcopy
--     → Supabase ダッシュボード > SQL Editor
--     → STEP ごとに選択して実行（SQL Editor は最後の1文の結果しか
--       表示しないため、まとめて流さないこと）
-- ================================================================


-- ================================================================
-- 【静的解析による事前予測】—— 実測でこれを検証する
-- ================================================================
--
--   anon が get_mention_candidates を呼んだときの評価:
--
--   1. Supabase の anon キーは JWT であり、その claims は
--        {"iss":"supabase", "ref":"...", "role":"anon", "iat":..., "exp":...}
--      role は【トップレベル】の claim であって app_metadata の中には無い。
--
--   2. get_my_role() は auth.jwt() -> 'app_metadata' ->> 'role' を返す
--      （fix_rls_policies_comprehensive.sql:58-63）。
--      anon の JWT には app_metadata が存在しないため
--        auth.jwt() -> 'app_metadata'  → NULL
--        NULL ->> 'role'               → NULL
--      よって get_my_role() は NULL。
--
--   3. auth.uid() は claims の 'sub' を読む。anon キーに sub は無いため NULL。
--
--   4. authorized CTE（add_mention_candidates_rpc.sql:77-93）の評価:
--        WHEN NULL IN ('admin','manager','staff')  → NULL（真ではない）→ 次へ
--        WHEN EXISTS (... uc.user_id = NULL ...)   → NULL 比較は真にならない
--                                                  → EXISTS は false → 次へ
--        ELSE false                                → ok = false
--
--   5. 本体の WHERE (SELECT ok FROM authorized) が false
--      → UNION ALL の両側とも 0 行。
--
--   → 予測: anon では 0 行が返る。情報漏洩は成立しない。
--
--   ただしこれは「ELSE false に落ちる」という三値論理の帰結であって、
--   「auth.uid() が NULL なら弾く」という明示的な意図の表明ではない。
--   ③ の答えは「結果的に閉じているが、設計として明示されていない」。
--
--   ★ 予測は予測でしかない。SECURITY DEFINER + 個人情報 + 推測可能な引数
--     という組み合わせで「たぶん大丈夫」を採用しない。以下で実測する。


-- ================================================================
-- STEP A : 静的情報（関数定義・返却列・権限・引数の推測容易性）
-- ================================================================
--   これ1本だけを選択して実行する。読み取り専用。
-- ----------------------------------------------------------------
SELECT * FROM (

  -- ① デプロイされている定義がリポジトリのファイルと一致しているか
  --    （SQL Editor から直接書き換えられている可能性を排除する）
  SELECT 1 AS sec, '① 関数の実体' AS section,
         'security / lang / 引数 / 戻り値'::text AS item,
         format('%s / %s / %s / %s',
                CASE WHEN p.prosecdef THEN 'DEFINER' ELSE 'INVOKER' END,
                l.lanname,
                pg_get_function_arguments(p.oid),
                pg_get_function_result(p.oid))::text AS value
  FROM   pg_proc p
  JOIN   pg_namespace n ON n.oid = p.pronamespace
  JOIN   pg_language  l ON l.oid = p.prolang
  WHERE  n.nspname='public' AND p.proname='get_mention_candidates'

  UNION ALL

  -- ② 本体に authorized ガードが実在するか（文字列で存在確認）
  --    定義そのものは長いので、要点だけを真偽で出す
  SELECT 2, '② 認可ガードの実在', 'authorized CTE がある',
         (SELECT CASE WHEN pg_get_functiondef(p.oid) ILIKE '%authorized%'
                      THEN 'あり' ELSE '★なし（要確認）' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname='get_mention_candidates')
  UNION ALL
  SELECT 2, '② 認可ガードの実在', 'ELSE false がある',
         (SELECT CASE WHEN pg_get_functiondef(p.oid) ILIKE '%ELSE false%'
                      THEN 'あり' ELSE '★なし（要確認）' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname='get_mention_candidates')
  UNION ALL
  SELECT 2, '② 認可ガードの実在', 'auth.uid() IS NULL の明示チェック',
         (SELECT CASE WHEN pg_get_functiondef(p.oid) ILIKE '%uid() IS NULL%'
                      THEN 'あり' ELSE 'なし（三値論理の ELSE false に依存）' END
          FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname='public' AND p.proname='get_mention_candidates')

  UNION ALL

  -- ③ 返却列の個人情報範囲
  --    関数が返すのは profiles.id / profiles.name / kind / companies.name。
  --    profiles には他に何が在るのかを並べ、「返していないが
  --    1列足せば返せてしまう位置にあるもの」を可視化する。
  SELECT 3, '③ profiles の全カラム（返却列との距離）', c.column_name::text,
         (c.data_type::text ||
          CASE WHEN c.column_name IN ('id','name') THEN '   ★この関数が返している'
               WHEN c.column_name IN ('phone')     THEN '   ⚠返していないが個人情報'
               ELSE '' END)::text
  FROM   information_schema.columns c
  WHERE  c.table_schema='public' AND c.table_name='profiles'

  UNION ALL

  -- ④ 実行権限の現状
  SELECT 4, '④ 実行権限', g.grantee::text,
         CASE WHEN has_function_privilege(g.grantee,
                     'public.get_mention_candidates(text)', 'EXECUTE')
              THEN '★EXECUTE あり' ELSE 'なし' END::text
  FROM   (VALUES ('anon'), ('authenticated'), ('service_role')) AS g(grantee)

  UNION ALL

  -- ⑤ 引数の推測容易性
  --    p_order_id が総当たりできるかどうかが危険度を左右する。
  --    実際の値は出さず、件数と形の情報だけを出す。
  SELECT 5, '⑤ 引数の推測容易性', 'orders 総件数（有効）',
         (SELECT count(*)::text FROM public.orders WHERE deleted_at IS NULL)
  UNION ALL
  SELECT 5, '⑤ 引数の推測容易性', 'id の文字数（最小〜最大）',
         (SELECT min(length(id))::text || ' 〜 ' || max(length(id))::text
          FROM public.orders)
  UNION ALL
  SELECT 5, '⑤ 引数の推測容易性', 'id が英字接頭辞+区切り+数字の形か',
         (SELECT count(*)::text || ' / ' || (SELECT count(*)::text FROM public.orders)
          FROM public.orders WHERE id ~ '^[A-Za-z]+[-_][0-9]')

) AS r
ORDER BY sec, item;


-- ================================================================
-- STEP B : anon の実測（★ 本命）
-- ================================================================
--   PostgREST が anon リクエストを処理するときの状態を再現する:
--     - DB ロールを anon に切り替える
--     - request.jwt.claims GUC に anon キーの claims 相当を入れる
--       （auth.uid() / auth.jwt() はこの GUC を読む）
--
--   SQL Editor は postgres ロールで動くため、何もしないと
--   anon の挙動にならない。ロールと JWT claims の両方を
--   合わせて初めて正確な再現になる。
--
--   ★ BEGIN 〜 ROLLBACK で囲っているので、実行後に状態は残らない。
--     SET LOCAL / set_config(..., true) はトランザクション終了で失効する。
--
--   ★ この STEP を丸ごと選択して実行すること。
--     「there is already a transaction in progress」という
--     WARNING が出ることがあるが無害（SQL Editor が既に
--     トランザクションを開いている場合）。
-- ----------------------------------------------------------------
BEGIN;

  -- 実在する案件番号を1つ GUC に退避する。
  -- anon に切り替えたあとは RLS で orders を読めなくなるため、
  -- 切替の【前】に取得しておく必要がある。
  SELECT set_config('elicheck.oid',
                    (SELECT id FROM public.orders
                     WHERE deleted_at IS NULL
                     ORDER BY created_at DESC LIMIT 1),
                    true) AS 使用する案件番号;

  -- anon キーの JWT claims 相当。
  -- role は app_metadata の中ではなくトップレベルにある点が重要。
  SELECT set_config('request.jwt.claims', '{"role":"anon"}', true);

  SET LOCAL ROLE anon;

  -- ここから anon として実行される
  SELECT
    'B-1 claims あり（旧 anon キー相当）'::text            AS ケース,
    current_user::text                                    AS 実行ロール,
    COALESCE(auth.uid()::text, '(NULL)')                  AS auth_uid,
    COALESCE(public.get_my_role(), '(NULL)')              AS get_my_role,
    (SELECT count(*) FROM public.get_mention_candidates(
       current_setting('elicheck.oid')))                  AS 返却行数;

ROLLBACK;


-- ----------------------------------------------------------------
-- STEP B-2 : claims が一切無いケース（★ こちらが本プロジェクトの実態）
-- ----------------------------------------------------------------
--   本プロジェクトの公開鍵は index.html:311 のとおり
--   sb_publishable_... 形式であり、旧来の JWT 形式 anon キーではない。
--
--   旧方式: anon キー自体が JWT で、その claims がそのまま
--           request.jwt.claims に入る（role=anon がトップレベルにある）
--   新方式: publishable key は JWT ではない。ゲートウェイが検証して
--           DB ロールを anon に解決する。未ログインなので
--           request.jwt.claims は空、または role だけの最小構成になる。
--
--   どちらでも app_metadata と sub は存在しないため
--   get_my_role() / auth.uid() は NULL になる、というのが予測。
--   B-1 と B-2 の両方を測って、経路によらず 0 行であることを確かめる。
-- ----------------------------------------------------------------
BEGIN;

  SELECT set_config('elicheck.oid',
                    (SELECT id FROM public.orders
                     WHERE deleted_at IS NULL
                     ORDER BY created_at DESC LIMIT 1),
                    true);

  -- claims を空にする（auth.jwt() が NULL を返す状態）
  SELECT set_config('request.jwt.claims', '', true);

  SET LOCAL ROLE anon;

  SELECT
    'B-2 claims なし（publishable key 相当）'::text        AS ケース,
    current_user::text                                    AS 実行ロール,
    COALESCE(auth.uid()::text, '(NULL)')                  AS auth_uid,
    COALESCE(public.get_my_role(), '(NULL)')              AS get_my_role,
    (SELECT count(*) FROM public.get_mention_candidates(
       current_setting('elicheck.oid')))                  AS 返却行数;

ROLLBACK;

-- ----------------------------------------------------------------
-- 【STEP B の判定】
--   期待（静的解析の予測）:
--     実行ロール   = anon
--     auth_uid     = (NULL)
--     get_my_role  = (NULL)
--     返却行数     = 0        ← ここが最重要
--
--   返却行数が 0 なら:
--     認可は機能している。危険度は「低」。
--     それでも多層防御として anon の EXECUTE は剥奪する。
--
--   返却行数が 1 以上なら:
--     ★ 未ログインの第三者が氏名・会社名を読み出せる状態。
--       危険度は「高」。即時に権限剥奪 + 関数内の認可強化を行う。
--
--   「permission denied for function get_mention_candidates」で
--   落ちた場合は、既に anon から剥奪済みということ（今回は該当しない想定）。
-- ----------------------------------------------------------------


-- ================================================================
-- STEP C : 認証済みだが無関係なユーザーの実測
-- ================================================================
--   anon が閉じていても、「ログインはできるが当該案件と無関係」な
--   ユーザーから読めるなら別の問題になる。
--   実在しない UUID を sub に据え、role=user として呼ぶ。
-- ----------------------------------------------------------------
BEGIN;

  SELECT set_config('elicheck.oid',
                    (SELECT id FROM public.orders
                     WHERE deleted_at IS NULL
                     ORDER BY created_at DESC LIMIT 1),
                    true);

  SELECT set_config('request.jwt.claims',
                    '{"sub":"00000000-0000-0000-0000-000000000001",'
                    '"app_metadata":{"role":"user"}}',
                    true);

  SET LOCAL ROLE authenticated;

  SELECT
    current_user::text                                    AS 実行ロール,
    COALESCE(auth.uid()::text, '(NULL)')                  AS auth_uid,
    COALESCE(public.get_my_role(), '(NULL)')              AS get_my_role,
    (SELECT count(*) FROM public.get_mention_candidates(
       current_setting('elicheck.oid')))                  AS 返却行数;

ROLLBACK;

-- ----------------------------------------------------------------
-- 【STEP C の判定】
--   期待: get_my_role = user / 返却行数 = 0
--     （user_companies に該当行が無いため authorized が false）
--   1 以上なら、案件番号を知る任意のログインユーザーが
--   他社の関係者一覧を読める。危険度「高」。
-- ----------------------------------------------------------------


-- ================================================================
-- STEP D : 社内ロールでの実測（＝認可が破られた場合の露出量）
-- ================================================================
--   正規の呼び出し。ここで返る件数が、
--   「もし認可が破られたら何件出るか」の上限になる。
--   危険度の見積もりに必要なので測る。
--
--   ★ 氏名そのものは出さない。件数と kind の内訳だけを見る。
--     調査のために個人情報を SQL Editor の結果画面や
--     会話ログに載せる必要は無い。
-- ----------------------------------------------------------------
BEGIN;

  SELECT set_config('elicheck.oid',
                    (SELECT id FROM public.orders
                     WHERE deleted_at IS NULL
                     ORDER BY created_at DESC LIMIT 1),
                    true);

  -- 実在する社内アカウントの UUID を sub に使う
  SELECT set_config('elicheck.sub',
                    (SELECT u.id::text FROM auth.users u
                     WHERE u.raw_app_meta_data ->> 'role'
                           IN ('admin','manager','staff')
                     ORDER BY u.created_at LIMIT 1),
                    true);

  SELECT set_config('request.jwt.claims',
                    json_build_object(
                      'sub', current_setting('elicheck.sub'),
                      'app_metadata', json_build_object('role', 'staff')
                    )::text,
                    true);

  SET LOCAL ROLE authenticated;

  SELECT
    kind                        AS 種別,
    count(*)                    AS 件数,
    count(company_name)         AS 会社名が入っている件数
  FROM public.get_mention_candidates(current_setting('elicheck.oid'))
  GROUP BY kind
  ORDER BY kind;

ROLLBACK;

-- ----------------------------------------------------------------
-- 【STEP D の判定】
--   kind='staff' の件数 = 社内スタッフの氏名が何件出るか
--   kind='user'  の件数 = その案件の会社に属する顧客が何件出るか
--
--   この合計が「1回の呼び出しで漏れる人数」。
--   案件番号を総当たりすれば会社ごとに繰り返せるため、
--   最終的には全社内スタッフ + 全顧客の氏名が集まる。
--   STEP B/C が 0 行であることが、この露出を防いでいる唯一の壁。
-- ----------------------------------------------------------------


-- ================================================================
-- STEP E : 決定的な確認 —— 実際の anon キーで HTTP から叩く
-- ================================================================
--   STEP B は DB 内でのシミュレーションであり、
--   PostgREST のロール切替・JWT 検証の経路は通っていない。
--   本番の攻撃経路そのものを再現するには HTTP から叩く必要がある。
--
--   ★ SQL ではないので、ターミナルで実行すること。
--   ★ 公開鍵を手で貼らない。index.html から変数に読み込む。
--     画面にもシェル履歴にも鍵が出ない形にしてある。
--
--   ── 1. 変数の準備（鍵は表示されない）────────────────────────
--
--     cd ~/Documents/hacchu-kanri
--     ANON=$(grep -oE 'sb_publishable_[A-Za-z0-9_-]+' index.html | head -1)
--     SUPA_URL=$(grep -oE 'https://[a-z0-9]+\.supabase\.co' index.html | head -1)
--     echo "URL=$SUPA_URL / 鍵の長さ=${#ANON}"
--
--       → 鍵そのものではなく長さだけを表示して、取得できたか確認する。
--         長さが 0 なら grep が失敗しているので先に直す。
--
--   ── 2. 疎通確認（★先にこれをやる）──────────────────────────
--
--     get_mention_candidates が [] を返したとき、それが
--     「認可が効いて 0 行」なのか「鍵や URL が間違っていて失敗」なのかを
--     区別する必要がある。先に必ず通る RPC を叩いて経路を確かめる。
--
--     curl -s -X POST "$SUPA_URL/rest/v1/rpc/get_my_role" \
--       -H "apikey: $ANON" \
--       -H "Authorization: Bearer $ANON" \
--       -H "Content-Type: application/json" \
--       -d '{}'
--
--       期待: null
--         → 経路は生きていて、anon には role が無い（= get_my_role が NULL）。
--           これが「疎通している」ことの証明になる。
--       {"message":"Invalid API key"} / 401 が出たら鍵か URL が誤り。
--         この状態で本番テストをしても [] は無意味なので先に直す。
--
--   ── 3. 本命：anon で get_mention_candidates を叩く ──────────
--
--     ORDER_ID='<STEP A で形式を確認した実在の案件番号>'
--
--     curl -s -X POST "$SUPA_URL/rest/v1/rpc/get_mention_candidates" \
--       -H "apikey: $ANON" \
--       -H "Authorization: Bearer $ANON" \
--       -H "Content-Type: application/json" \
--       -d "{\"p_order_id\":\"$ORDER_ID\"}"
--
--   ── 4. 判定 ────────────────────────────────────────────────
--
--     []
--       → 0 行。認可が機能している。危険度「低」。
--         それでも多層防御として anon の EXECUTE は剥奪する。
--
--     [{"id":"...","name":"...", ...}] のように氏名が返る
--       → ★未ログインの第三者が実際に読み出せる。危険度「高」。
--         直ちに権限剥奪 + 関数内の認可強化を行う。
--         ※ 返ってきた氏名は会話や issue に貼らないこと。
--           件数と「氏名が入っていたか」だけ報告すれば判断できる。
--
--     {"code":"42501"} / "permission denied for function"
--       → 既に anon から剥奪済み（今回は該当しない想定）。
--
--   ── 5. 後片付け ────────────────────────────────────────────
--
--     unset ANON SUPA_URL ORDER_ID
-- ================================================================


-- ================================================================
-- 調査後の対処（このファイルには含めない・別ファイルで実施）
-- ================================================================
--   結果によらず実施するもの:
--     - get_mention_candidates / get_my_role から anon の EXECUTE を剥奪
--       （REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon）
--
--   STEP B または C が 1 行以上だった場合に追加で実施するもの:
--     - 関数の先頭で auth.uid() IS NULL を明示的に弾く
--     - authorized CTE が三値論理の ELSE に依存しない形に書き換える
-- ================================================================
