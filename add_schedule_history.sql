-- ================================================================
-- E-Li 工事受発注システム — schedule_history テーブル
-- 日程変更履歴を管理するテーブル
-- ================================================================

-- ----------------------------------------------------------------
-- 1. テーブル作成
-- ----------------------------------------------------------------
CREATE TABLE schedule_history (
  id           uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  schedule_id  uuid        NOT NULL REFERENCES schedules(id) ON DELETE CASCADE,
  order_id     text        NOT NULL,
  prev_date    date,
  prev_start   time,
  prev_end     time,
  new_date     date,
  new_start    time,
  new_end      time,
  changed_at   timestamptz DEFAULT now()
);

-- ----------------------------------------------------------------
-- 2. RLS 有効化
-- ----------------------------------------------------------------
ALTER TABLE schedule_history ENABLE ROW LEVEL SECURITY;

-- ----------------------------------------------------------------
-- 3. ポリシー
-- ----------------------------------------------------------------

-- ユーザー: 自分の注文の変更履歴を読める
CREATE POLICY "users_read_own_schedule_history"
  ON schedule_history FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = schedule_history.order_id
        AND orders.user_id = auth.uid()
    )
  );

-- 管理者・スタッフ: 全変更履歴を読める
CREATE POLICY "admins_read_all_schedule_history"
  ON schedule_history FOR SELECT
  USING (
    (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );

-- 管理者・スタッフ: 変更履歴を登録できる
CREATE POLICY "admins_insert_schedule_history"
  ON schedule_history FOR INSERT
  WITH CHECK (
    (auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'staff')
  );
