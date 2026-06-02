-- ================================================================
-- 1. profiles.company_id が NULL の既存ユーザーに MK-A3X9 を設定
-- ================================================================
-- Supabase ダッシュボード > SQL Editor で実行してください
-- ================================================================

-- 実行前確認（NULLユーザーの一覧）
-- SELECT id, name, company_id FROM profiles WHERE company_id IS NULL;

UPDATE profiles
SET    company_id = 'MK-A3X9'
WHERE  company_id IS NULL;

-- 実行後確認
-- SELECT id, name, company_id FROM profiles WHERE company_id = 'MK-A3X9';
