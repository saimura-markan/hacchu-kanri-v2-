-- ================================================================
-- messages.order_id にインデックスを追加
--
-- 目的:
--   Supabase Realtime の postgres_changes で filter オプションを
--   使う場合、フィルター対象カラムにインデックスが必要。
--   このインデックスがないと filter が無言で失敗し、
--   Realtime イベントが届かない。
--
-- 現在の暫定対応:
--   filter オプションを削除してクライアントサイドで絞り込み中。
--   このインデックスを適用すると filter 付きに戻すことができる。
-- ================================================================

CREATE INDEX IF NOT EXISTS idx_messages_order_id ON messages (order_id);

-- schedules も同様にインデックスを追加（Realtime・クエリ性能向上）
CREATE INDEX IF NOT EXISTS idx_schedules_order_id ON schedules (order_id);
