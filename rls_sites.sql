-- ================================================================
-- E-Li 工事受発注システム — sites テーブル RLS ポリシー
-- ================================================================
-- 目的: ログインユーザーの company_id（profiles テーブル参照）と
--       一致する sites のみ SELECT/INSERT/UPDATE/DELETE できるよう制限。
--       admin / staff ロールは全社データにアクセス可能。
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

-- ----------------------------------------------------------------
-- 1. 既存ポリシーをすべて削除（冪等性のため）
-- ----------------------------------------------------------------
DROP POLICY IF EXISTS "users_read_own_company_sites"   ON sites;
DROP POLICY IF EXISTS "users_insert_own_company_sites" ON sites;
DROP POLICY IF EXISTS "users_update_own_company_sites" ON sites;
DROP POLICY IF EXISTS "users_delete_own_company_sites" ON sites;
DROP POLICY IF EXISTS "admins_read_all_sites"          ON sites;
DROP POLICY IF EXISTS "admins_write_all_sites"         ON sites;

-- ----------------------------------------------------------------
-- 2. RLS 有効化
-- ----------------------------------------------------------------
ALTER TABLE sites ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- 共通サブクエリ説明:
--   (SELECT company_id FROM profiles WHERE id = auth.uid())
--   → ログイン中のユーザーの company_id を profiles テーブルから取得
-- ----------------------------------------------------------------

-- ----------------------------------------------------------------
-- 3. SELECT: 自社の現場のみ読める
-- ----------------------------------------------------------------
CREATE POLICY "users_read_own_company_sites"
  ON sites FOR SELECT
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );

-- ----------------------------------------------------------------
-- 4. INSERT: 自社の現場のみ登録できる
-- ----------------------------------------------------------------
CREATE POLICY "users_insert_own_company_sites"
  ON sites FOR INSERT
  WITH CHECK (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );

-- ----------------------------------------------------------------
-- 5. UPDATE: 自社の現場のみ更新できる
-- ----------------------------------------------------------------
CREATE POLICY "users_update_own_company_sites"
  ON sites FOR UPDATE
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  )
  WITH CHECK (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );

-- ----------------------------------------------------------------
-- 6. DELETE: 自社の現場のみ削除できる
-- ----------------------------------------------------------------
CREATE POLICY "users_delete_own_company_sites"
  ON sites FOR DELETE
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );

-- ----------------------------------------------------------------
-- 確認クエリ（適用後に実行して確認 — 4件表示されれば OK）
-- ----------------------------------------------------------------
-- SELECT policyname, cmd, qual
-- FROM pg_policies
-- WHERE tablename = 'sites'
-- ORDER BY cmd;
