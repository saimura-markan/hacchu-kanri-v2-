-- ================================================================
-- E-Li 工事受発注システム — メンション候補取得 RPC
--   get_mention_candidates(p_order_id bigint)
--
--   目的:
--     チャット画面（案Bのメンション宛先ピッカー）で、
--     当該案件（order）に関係するメンション候補を安全に取得する。
--     クライアントから profiles を直接一覧 SELECT できない
--     （RLS で一般ユーザーは自分の1行しか読めない）ため、
--     mark_messages_read と同じく SECURITY DEFINER の RPC 経由で返す。
--
--   実装パターン:
--     alter_messages_for_chat.sql の mark_messages_read を踏襲。
--     SECURITY DEFINER + search_path 明示固定。
--
--   除外仕様:
--     profiles.is_system = true（「インフォ さん」等の通知用システム
--     アカウント）は staff / user いずれの候補からも除外する。
--
--   Supabase ダッシュボード > SQL Editor で実行してください。
-- ================================================================

-- ----------------------------------------------------------------
-- 【重要・設計上の注意】ロールの参照元について
-- ----------------------------------------------------------------
--   本システムのロール（admin/manager/staff/user）は
--   profiles テーブルには存在せず、Supabase Auth の
--   auth.users.raw_app_meta_data ->> 'role'（＝JWTの app_metadata）
--   に格納されている。get_my_role() もここを参照している。
--
--   そのため「社内ユーザー全員（role in admin/manager/staff）」の
--   判定は profiles.role ではなく auth.users.raw_app_meta_data から
--   行う。SECURITY DEFINER（関数所有者 = 特権ロール）で実行するため、
--   auth スキーマの参照が可能。
--
--   ※ 呼び出し元自身のロール判定には既存の get_my_role() を使用。
--     （auth.jwt() ベースなので、他ユーザーのロール判定には使えない）
-- ----------------------------------------------------------------

-- ----------------------------------------------------------------
-- 【型についての確認結果（DDL 一次情報より）】
--   orders.id            → text
--   orders.company_id    → text
--   companies.id         → text  （FK: user_companies/cases.company_id text REFERENCES companies(id)）
--   user_companies.company_id → text
--   したがって company_id の比較はすべて text 同士。
--   明示・暗黙いずれのキャストも不要。
--
--   p_order_id は text（orders.id が text のため）。
--   旧・bigint 版が既に存在する場合に備えて先に DROP する
--   （引数型が変わるとシグネチャが変わり CREATE OR REPLACE では
--     置き換えられず別関数になるため）。
-- ----------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_mention_candidates(bigint);

CREATE OR REPLACE FUNCTION public.get_mention_candidates(p_order_id text)
RETURNS TABLE (
  id           uuid,
  name         text,
  kind         text,
  company_name text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  WITH ord AS (
    -- 2. p_order_id から対象案件の company_id を取得
    SELECT o.company_id AS company_id
    FROM orders o
    WHERE o.id = p_order_id
  ),
  me AS (
    SELECT get_my_role() AS role,
           auth.uid()    AS uid
  ),
  authorized AS (
    -- 3. 権限チェック
    SELECT
      CASE
        -- 社内（admin/manager/staff）は無条件で通過
        WHEN (SELECT role FROM me) IN ('admin', 'manager', 'staff') THEN true
        -- 顧客（user）は、当該 order の company_id に
        -- user_companies 経由で自分が紐づいている場合のみ通過
        WHEN EXISTS (
          SELECT 1
          FROM user_companies uc
          WHERE uc.user_id    = (SELECT uid FROM me)
            AND uc.company_id = (SELECT company_id FROM ord)
        ) THEN true
        ELSE false
      END AS ok
  )

  -- 4-a. 社内ユーザー全員（role in admin/manager/staff）、kind='staff'
  SELECT
    p.id,
    p.name,
    'staff'::text AS kind,
    NULL::text    AS company_name   -- 社内ユーザーは案件会社に属さないため NULL
  FROM profiles p
  JOIN auth.users u ON u.id = p.id
  WHERE (SELECT ok FROM authorized)
    AND u.raw_app_meta_data ->> 'role' IN ('admin', 'manager', 'staff')
    AND p.is_system = false         -- システムアカウント（通知用）は除外
    AND p.name IS NOT NULL          -- name が NULL の行は除外

  UNION ALL

  -- 4-b. 当該 company_id に紐づく顧客ユーザー全員、kind='user'
  SELECT
    p.id,
    p.name,
    'user'::text AS kind,
    (SELECT c.name FROM companies c
      WHERE c.id = (SELECT company_id FROM ord)) AS company_name
  FROM profiles p
  JOIN user_companies uc ON uc.user_id = p.id
  JOIN auth.users     u  ON u.id       = p.id
  WHERE (SELECT ok FROM authorized)
    AND uc.company_id = (SELECT company_id FROM ord)
    -- 社内ユーザーが user_companies に混在していても staff 側でのみ扱う
    AND COALESCE(u.raw_app_meta_data ->> 'role', 'user') = 'user'
    AND p.is_system = false         -- システムアカウント（通知用）は除外
    AND p.name IS NOT NULL;         -- name が NULL の行は除外
$$;

-- ----------------------------------------------------------------
-- 5. 実行権限の付与
-- ----------------------------------------------------------------
REVOKE ALL     ON FUNCTION public.get_mention_candidates(text) FROM public;
GRANT  EXECUTE ON FUNCTION public.get_mention_candidates(text) TO   authenticated;

-- ----------------------------------------------------------------
-- 動作確認クエリ（実行後にコメントを外して確認）
-- ----------------------------------------------------------------
-- 社内ユーザーでログインしたセッションから（p_order_id は text リテラル）:
--   SELECT * FROM get_mention_candidates('B-2024-101');
--
-- 期待:
--   ・社内ユーザーが kind='staff'（company_name=NULL）で列挙される
--   ・当該案件の会社に紐づく顧客が kind='user'（company_name=会社名）で列挙される
--   ・name が NULL の行は含まれない
--   ・権限のない顧客が呼ぶと 0 行
