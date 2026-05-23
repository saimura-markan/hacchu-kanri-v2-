-- ================================================================
-- E-Li 工事受発注システム — companies テーブル is_active 追加
-- Supabase SQL Editor で実行してください
-- ================================================================

-- 1. is_active カラム追加（既存レコードはすべて有効扱い）
ALTER TABLE companies
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;

-- 2. RLS 有効化
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;

-- 3. 全員（未ログイン含む）: is_active=true の企業のみ SELECT 可（登録時の照合用）
CREATE POLICY "read_active_companies"
  ON companies FOR SELECT
  USING (is_active = true);

-- 4. 管理者: 有効・無効問わず全企業 SELECT（管理画面の一覧表示用）
CREATE POLICY "admins_read_all_companies"
  ON companies FOR SELECT
  USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

-- 5. 管理者: 新規企業 INSERT
CREATE POLICY "admins_insert_companies"
  ON companies FOR INSERT
  WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

-- 6. 管理者: is_active 切り替え等の UPDATE
CREATE POLICY "admins_update_companies"
  ON companies FOR UPDATE
  USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');
