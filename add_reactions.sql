-- messages テーブルにリアクション（スタンプ）カラムを追加
-- Supabase ダッシュボード → SQL Editor で実行してください
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reactions jsonb DEFAULT '{}';
