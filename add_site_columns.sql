-- ================================================================
-- E-Li 現場情報管理ページ — sites テーブル カラム追加
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください

ALTER TABLE sites ADD COLUMN IF NOT EXISTS key_info      text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS key_images    jsonb   DEFAULT '[]';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS parking_info  text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS parking_images jsonb  DEFAULT '[]';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS contact_name  text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS contact_phone text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS entry_info    text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS entry_images  jsonb   DEFAULT '[]';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS yosei_info    text    DEFAULT '';
ALTER TABLE sites ADD COLUMN IF NOT EXISTS yosei_images  jsonb   DEFAULT '[]';

-- 既存カラムの転用（変更不要）
-- memo       → 現場注意事項（テキスト）
-- images     → 現場注意事項（写真/PDF）

-- 確認クエリ
-- SELECT column_name, data_type, column_default
-- FROM information_schema.columns
-- WHERE table_name = 'sites'
-- ORDER BY ordinal_position;
