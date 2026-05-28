-- ================================================================
-- E-Li — 氏名ふりがな対応 カラム追加
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください

-- profiles: ふりがな
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS name_kana TEXT DEFAULT '';

-- orders: 担当者ふりがな（発注時に profiles.name_kana からコピー）
ALTER TABLE orders ADD COLUMN IF NOT EXISTS person_kana TEXT DEFAULT '';

-- 確認クエリ
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_name IN ('profiles','orders') AND column_name IN ('name_kana','person_kana')
-- ORDER BY table_name, column_name;
