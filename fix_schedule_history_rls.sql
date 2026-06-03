-- ================================================================
-- schedule_history RLS ポリシー修正
-- 既存の app_metadata ポリシーを user_metadata / manager 対応に更新
-- ================================================================

-- 既存ポリシーを削除
DROP POLICY IF EXISTS "admins_read_all_schedule_history"  ON schedule_history;
DROP POLICY IF EXISTS "admins_insert_schedule_history"   ON schedule_history;

-- SELECT: admin / manager / staff が全履歴を読める
-- INSERT: admin / manager / staff が履歴を登録できる
-- user_metadata と app_metadata の両方をチェック（どちらに設定していても動作）

CREATE POLICY "admins_read_all_schedule_history"
  ON schedule_history FOR SELECT
  USING (
    (auth.jwt() -> 'user_metadata' ->> 'role') IN ('admin', 'manager', 'staff')
    OR (auth.jwt() -> 'app_metadata'  ->> 'role') IN ('admin', 'manager', 'staff')
  );

CREATE POLICY "admins_insert_schedule_history"
  ON schedule_history FOR INSERT
  WITH CHECK (
    (auth.jwt() -> 'user_metadata' ->> 'role') IN ('admin', 'manager', 'staff')
    OR (auth.jwt() -> 'app_metadata'  ->> 'role') IN ('admin', 'manager', 'staff')
  );
