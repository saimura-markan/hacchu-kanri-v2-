-- ================================================================
-- E-Li 工事受発注システム — ordersテーブル 不足カラム追加
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

-- 担当者名（profiles.name からコピーして保存）
ALTER TABLE orders ADD COLUMN IF NOT EXISTS person             TEXT DEFAULT '';

-- 担当者電話番号（profiles.phone からコピーして保存）
ALTER TABLE orders ADD COLUMN IF NOT EXISTS phone              TEXT DEFAULT '';

-- 担当者ふりがな（profiles.name_kana からコピーして保存）
ALTER TABLE orders ADD COLUMN IF NOT EXISTS person_kana        TEXT DEFAULT '';

-- 現場担当者名
ALTER TABLE orders ADD COLUMN IF NOT EXISTS site_contact_name  TEXT DEFAULT '';

-- 現場担当者電話番号
ALTER TABLE orders ADD COLUMN IF NOT EXISTS site_contact_phone TEXT DEFAULT '';

-- ----------------------------------------------------------------
-- 確認クエリ（実行後コメントを外して確認）
-- ----------------------------------------------------------------
-- SELECT column_name, data_type, column_default
-- FROM information_schema.columns
-- WHERE table_name = 'orders'
--   AND column_name IN ('person','phone','person_kana','site_contact_name','site_contact_phone')
-- ORDER BY column_name;
