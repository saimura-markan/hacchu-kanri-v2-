-- ================================================================
-- orders テーブルに論理削除用カラムを追加
-- ================================================================

ALTER TABLE orders ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;

-- 通常一覧クエリ（deleted_at IS NULL）のパフォーマンス向上
CREATE INDEX IF NOT EXISTS idx_orders_deleted_at ON orders (deleted_at);
