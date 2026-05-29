-- ================================================================
-- E-Li 工事受発注システム — sites テーブル カラム追加
-- 現場担当者名・現場担当者電話番号
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

ALTER TABLE sites ADD COLUMN IF NOT EXISTS site_contact_name  text DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS site_contact_phone text DEFAULT '';

-- ----------------------------------------------------------------
-- 確認クエリ
-- ----------------------------------------------------------------
-- SELECT column_name, data_type, column_default
-- FROM information_schema.columns
-- WHERE table_name = 'sites'
--   AND column_name IN ('site_contact_name', 'site_contact_phone')
-- ORDER BY column_name;
