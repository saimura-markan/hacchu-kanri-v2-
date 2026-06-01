-- messages テーブルに送信者名カラムを追加
-- Supabase ダッシュボード → SQL Editor で実行してください
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS sender_name text;
