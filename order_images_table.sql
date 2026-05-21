-- ================================================================
-- order_images テーブル作成・RLS設定
--
-- Supabase Storage の設定（Storageメニューで手動操作）
--   1. New bucket → 名前: order-images
--   2. Public bucket: ON（公開URLで画像表示）
-- ================================================================

CREATE TABLE order_images (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     uuid        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  storage_path text        NOT NULL,
  created_at   timestamptz DEFAULT now()
);

CREATE INDEX idx_order_images_order_id ON order_images (order_id);

ALTER TABLE order_images ENABLE ROW LEVEL SECURITY;

-- ユーザー: 自分の注文の画像を読める
CREATE POLICY "users_read_own_images"
  ON order_images FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM orders
    WHERE orders.id = order_images.order_id
      AND orders.user_id = auth.uid()
  ));

-- 管理者: 全画像を読める
CREATE POLICY "admins_read_all_images"
  ON order_images FOR SELECT
  USING ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');

-- ユーザー: 自分の注文に画像を追加できる
CREATE POLICY "users_insert_own_images"
  ON order_images FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM orders
    WHERE orders.id = order_images.order_id
      AND orders.user_id = auth.uid()
  ));
