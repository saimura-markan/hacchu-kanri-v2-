-- messages テーブルに送信者 UUID カラムを追加
-- Supabase ダッシュボード → SQL Editor で実行してください
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS sender_id uuid REFERENCES auth.users(id);
