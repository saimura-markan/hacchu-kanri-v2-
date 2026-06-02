-- ================================================================
-- E-Li 工事受発注システム — RLS ポリシー設定
-- 対象テーブル: orders / schedules / messages
-- ================================================================

-- ----------------------------------------------------------------
-- 1. RLS 有効化
-- ----------------------------------------------------------------
ALTER TABLE orders    ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages  ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- 2. orders テーブル
-- ----------------------------------------------------------------

-- ユーザー: 自分の注文だけ読める
CREATE POLICY "users_read_own_orders"
  ON orders FOR SELECT
  USING (user_id = auth.uid());

-- 管理者: 全注文を読める
CREATE POLICY "admins_read_all_orders"
  ON orders FOR SELECT
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- ユーザー: 自分の注文として登録できる（user_id を強制）
CREATE POLICY "users_insert_own_orders"
  ON orders FOR INSERT
  WITH CHECK (user_id = auth.uid());

-- 管理者: ステータス等を更新できる
CREATE POLICY "admins_update_orders"
  ON orders FOR UPDATE
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- ----------------------------------------------------------------
-- 3. schedules テーブル（orders に紐づく）
-- ----------------------------------------------------------------

-- ユーザー: 自分の注文のスケジュールを読める
CREATE POLICY "users_read_own_schedules"
  ON schedules FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = schedules.order_id
        AND orders.user_id = auth.uid()
    )
  );

-- 管理者: 全スケジュールを読める
CREATE POLICY "admins_read_all_schedules"
  ON schedules FOR SELECT
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- ユーザー/管理者: スケジュール登録（自分の注文に紐づくもののみ）
CREATE POLICY "insert_schedules_for_own_orders"
  ON schedules FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = schedules.order_id
        AND orders.user_id = auth.uid()
    )
    OR (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

-- ----------------------------------------------------------------
-- 4. messages テーブル（orders に紐づく）
-- ----------------------------------------------------------------

-- ユーザー: 自分の注文のメッセージを読める
CREATE POLICY "users_read_own_messages"
  ON messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = messages.order_id
        AND orders.user_id = auth.uid()
    )
  );

-- 管理者: 全メッセージを読める
CREATE POLICY "admins_read_all_messages"
  ON messages FOR SELECT
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- ユーザー: 自分の注文にメッセージを送れる
CREATE POLICY "users_insert_own_messages"
  ON messages FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = messages.order_id
        AND orders.user_id = auth.uid()
    )
    OR (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
  );

-- ----------------------------------------------------------------
-- 5. orders.user_id を INSERT 時に自動セットするトリガー
--    （saveToSupabase で user_id を明示していないため）
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_order_user_id()
RETURNS TRIGGER AS $$
BEGIN
  NEW.user_id := auth.uid();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_set_order_user_id
  BEFORE INSERT ON orders
  FOR EACH ROW
  EXECUTE FUNCTION set_order_user_id();

-- ----------------------------------------------------------------
-- 確認クエリ
-- ----------------------------------------------------------------
-- SELECT schemaname, tablename, policyname, cmd, qual
-- FROM pg_policies
-- WHERE tablename IN ('orders', 'schedules', 'messages')
-- ORDER BY tablename, cmd;
