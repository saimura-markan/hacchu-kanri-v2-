-- ================================================================
-- E-Li 工事受発注システム — RLS ポリシー 包括的修正
-- 実行場所: Supabase ダッシュボード → SQL Editor
-- ================================================================
--
-- 修正内容:
--   0. ロール判定関数（app_metadata + user_metadata 両対応）
--   1. orders    : manager/staff 読み取り追加、UPDATE ポリシー追加
--   2. schedules : manager/staff 読み取り追加、UPDATE ポリシー追加
--   3. messages  : manager/staff 読み取り追加、UPDATE ポリシー追加（既読処理）
--   4. sites     : manager をアクセス許可に追加
--   5. profiles  : manager/staff 読み取り追加
--   6. schedule_history : manager 追加
--   7. order_images     : manager/staff 追加
-- ================================================================


-- ================================================================
-- 0. ロール判定ヘルパー関数
--    ダッシュボードから設定した user_metadata にも対応するため
--    app_metadata → user_metadata の順でフォールバックする
-- ================================================================
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    auth.jwt() -> 'app_metadata' ->> 'role',
    auth.jwt() -> 'user_metadata' ->> 'role'
  )
$$;


-- ================================================================
-- 1. orders テーブル
-- ================================================================

-- 既存ポリシーを削除（冪等実行）
DROP POLICY IF EXISTS "admins_read_all_orders"   ON orders;
DROP POLICY IF EXISTS "admins_update_orders"      ON orders;

-- 管理者・manager・staff: 全注文を読める
CREATE POLICY "admins_read_all_orders"
  ON orders FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));

-- 管理者・manager: ステータス変更・論理削除などの更新ができる
CREATE POLICY "admins_update_orders"
  ON orders FOR UPDATE
  USING    (get_my_role() IN ('admin', 'manager'))
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

-- 管理者: 注文を追加できる（電話受注などの手動登録用）
DROP POLICY IF EXISTS "admins_insert_orders" ON orders;
CREATE POLICY "admins_insert_orders"
  ON orders FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

-- 既存のユーザー用ポリシーは残す（user_id 紐付け）
-- "users_read_own_orders"   → そのまま維持
-- "users_insert_own_orders" → そのまま維持


-- ================================================================
-- 2. schedules テーブル
-- ================================================================

-- 既存ポリシーを削除
DROP POLICY IF EXISTS "admins_read_all_schedules" ON schedules;

-- 管理者・manager・staff: 全スケジュールを読める
CREATE POLICY "admins_read_all_schedules"
  ON schedules FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));

-- 管理者・manager: スケジュールを更新できる（日程変更）
DROP POLICY IF EXISTS "admins_update_schedules" ON schedules;
CREATE POLICY "admins_update_schedules"
  ON schedules FOR UPDATE
  USING    (get_my_role() IN ('admin', 'manager'))
  WITH CHECK (get_my_role() IN ('admin', 'manager'));

-- 既存の INSERT ポリシーに manager を追加
DROP POLICY IF EXISTS "insert_schedules_for_own_orders" ON schedules;
CREATE POLICY "insert_schedules_for_own_orders"
  ON schedules FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = schedules.order_id
        AND orders.user_id = auth.uid()
    )
    OR get_my_role() IN ('admin', 'manager')
  );


-- ================================================================
-- 3. messages テーブル
-- ================================================================

-- 既存ポリシーを削除
DROP POLICY IF EXISTS "admins_read_all_messages"   ON messages;
DROP POLICY IF EXISTS "users_insert_own_messages"  ON messages;

-- 管理者・manager・staff: 全メッセージを読める
CREATE POLICY "admins_read_all_messages"
  ON messages FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));

-- INSERT: 自分の注文に送れる OR 管理者側
CREATE POLICY "users_insert_own_messages"
  ON messages FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = messages.order_id
        AND orders.user_id = auth.uid()
    )
    OR get_my_role() IN ('admin', 'manager', 'staff')
  );

-- UPDATE: 既読処理（read_by 配列の更新）
--   自分の注文に紐づくメッセージ OR 管理者側 が更新できる
DROP POLICY IF EXISTS "users_update_own_messages"  ON messages;
DROP POLICY IF EXISTS "admins_update_messages"     ON messages;
CREATE POLICY "messages_update"
  ON messages FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = messages.order_id
        AND orders.user_id = auth.uid()
    )
    OR get_my_role() IN ('admin', 'manager', 'staff')
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = messages.order_id
        AND orders.user_id = auth.uid()
    )
    OR get_my_role() IN ('admin', 'manager', 'staff')
  );


-- ================================================================
-- 4. sites テーブル（manager を追加）
-- ================================================================

DROP POLICY IF EXISTS "users_read_own_company_sites"   ON sites;
DROP POLICY IF EXISTS "users_insert_own_company_sites" ON sites;
DROP POLICY IF EXISTS "users_update_own_company_sites" ON sites;
DROP POLICY IF EXISTS "users_delete_own_company_sites" ON sites;
DROP POLICY IF EXISTS "admins_read_all_sites"          ON sites;
DROP POLICY IF EXISTS "admins_write_all_sites"         ON sites;

-- SELECT: 自社の現場のみ OR 管理者側
CREATE POLICY "users_read_own_company_sites"
  ON sites FOR SELECT
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR get_my_role() IN ('admin', 'manager', 'staff')
  );

-- INSERT: 自社の現場のみ OR 管理者側
CREATE POLICY "users_insert_own_company_sites"
  ON sites FOR INSERT
  WITH CHECK (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR get_my_role() IN ('admin', 'manager', 'staff')
  );

-- UPDATE: 自社の現場のみ OR 管理者側
CREATE POLICY "users_update_own_company_sites"
  ON sites FOR UPDATE
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR get_my_role() IN ('admin', 'manager', 'staff')
  )
  WITH CHECK (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR get_my_role() IN ('admin', 'manager', 'staff')
  );

-- DELETE: 自社の現場のみ OR admin/manager のみ
CREATE POLICY "users_delete_own_company_sites"
  ON sites FOR DELETE
  USING (
    company_id = (SELECT company_id FROM profiles WHERE id = auth.uid())
    OR get_my_role() IN ('admin', 'manager')
  );


-- ================================================================
-- 5. profiles テーブル（manager/staff 読み取り追加）
-- ================================================================

DROP POLICY IF EXISTS "admins_read_all_profiles" ON profiles;

-- 管理者・manager・staff: 全プロフィールを読める（担当者名の表示に必要）
CREATE POLICY "admins_read_all_profiles"
  ON profiles FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));


-- ================================================================
-- 6. schedule_history テーブル（manager を追加）
-- ================================================================

DROP POLICY IF EXISTS "admins_read_all_schedule_history"   ON schedule_history;
DROP POLICY IF EXISTS "admins_insert_schedule_history"     ON schedule_history;

CREATE POLICY "admins_read_all_schedule_history"
  ON schedule_history FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));

CREATE POLICY "admins_insert_schedule_history"
  ON schedule_history FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager', 'staff'));


-- ================================================================
-- 7. order_images テーブル（manager/staff 読み取り追加）
-- ================================================================

DROP POLICY IF EXISTS "admins_read_all_images" ON order_images;

CREATE POLICY "admins_read_all_images"
  ON order_images FOR SELECT
  USING (get_my_role() IN ('admin', 'manager', 'staff'));

-- INSERT: 自分の注文 OR 管理者側
DROP POLICY IF EXISTS "admins_insert_images" ON order_images;
CREATE POLICY "admins_insert_images"
  ON order_images FOR INSERT
  WITH CHECK (get_my_role() IN ('admin', 'manager', 'staff'));


-- ================================================================
-- 動作確認クエリ（実行後にこれで確認）
-- ================================================================
-- SELECT tablename, policyname, cmd,
--        roles, qual
-- FROM pg_policies
-- WHERE tablename IN (
--   'orders','schedules','messages',
--   'sites','profiles','schedule_history','order_images'
-- )
-- ORDER BY tablename, cmd;


-- ================================================================
-- 【補足】ロールが user_metadata に設定されている場合の移行
--   Supabase ダッシュボードの「Edit User」から設定した role は
--   user_metadata に入る。get_my_role() 関数が両方に対応しているため
--   移行作業は不要だが、app_metadata に統一したい場合は以下を実行。
-- ================================================================
-- UPDATE auth.users
-- SET app_metadata = app_metadata || jsonb_build_object('role', user_metadata ->> 'role')
-- WHERE user_metadata ->> 'role' IS NOT NULL
--   AND (app_metadata ->> 'role') IS NULL;
-- ================================================================
