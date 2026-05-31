-- ================================================================
-- messagesテーブルにリプライ・メンション・既読カラムを追加
-- Supabase ダッシュボード → SQL Editor で実行
-- ================================================================

-- カラム追加
-- ※ reply_to_id の型はmessages.idの型に合わせてください（bigint or uuid）
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reply_to_id bigint,
  ADD COLUMN IF NOT EXISTS mentions     text[]  DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS read_by      text[]  DEFAULT '{}';

-- 既読管理RPC: admin/manager/staffが開いたときに一括で既読登録
CREATE OR REPLACE FUNCTION mark_messages_read(p_order_id text, p_email text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.messages
  SET read_by = array_append(COALESCE(read_by, '{}'), p_email)
  WHERE order_id = p_order_id
    AND NOT (p_email = ANY(COALESCE(read_by, '{}')));
$$;
