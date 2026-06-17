-- companiesテーブルにaddressカラムを追加
-- Supabase SQL Editor で実行してください

ALTER TABLE companies
  ADD COLUMN IF NOT EXISTS address text DEFAULT '';
