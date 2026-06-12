-- ================================================================
-- E-Li 工事受発注システム — RLS ポリシー 包括的修正
-- 実行場所: Supabase ダッシュボード → SQL Editor
-- ================================================================
--
-- 【重要】実行順序
--   STEP 1: 下部の「ロール移行SQL」を先に実行する
--   STEP 2: このファイルの残りを実行する
--
-- 修正内容:
--   0. ロール判定関数（app_metadata のみ参照・安全版）
--   1. orders    : manager/staff 読み取り追加、UPDATE ポリシー追加
--   2. schedules : manager/staff 読み取り追加、UPDATE ポリシー追加
--   3. messages  : manager/staff 読み取り追加、UPDATE ポリシー追加（既読処理）
--   4. sites     : manager をアクセス許可に追加
--   5. profiles  : manager/staff 読み取り追加
--   6. schedule_history : manager 追加
--   7. order_images     : manager/staff 追加
-- ================================================================


-- ================================================================
-- STEP 1: ロール移行SQL（このファイルの他の部分より先に実行）
-- ================================================================
-- user_metadata に設定されたロールを app_metadata へ移行する。
--
-- 【なぜ必要か】
--   user_metadata はユーザー自身が supabase.auth.updateUser() で
--   自由に書き換えられるため、認可判定に使うと権限昇格が可能になる。
--   app_metadata はサービスロールキーでのみ書き込めるため安全。
--
-- 以下を SQL Editor で実行後、STEP 2 へ進む:
--
-- UPDATE auth.users
-- SET raw_app_meta_data = raw_app_meta_data ||
--       jsonb_build_object('role', raw_user_meta_data ->> 'role')
-- WHERE raw_user_meta_data ->> 'role' IS NOT NULL
--   AND (raw_app_meta_data ->> 'role') IS NULL;
--
-- 実行結果で更新行数を確認し、対象ユーザーが正しく移行されたことを確認すること。
-- 移行後は Dashboard > Authentication > Users でも app_metadata に role が
-- 表示されることを確認する。
--
-- 【今後のロール設定方法】
--   Dashboard の「Edit User」(user_metadata) ではなく、
--   SQL Editor から以下のように app_metadata に直接設定する:
--
--   UPDATE auth.users
--   SET raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
--   WHERE email = 'xxx@markan.co.jp';
-- ================================================================


-- ================================================================
-- STEP 2: ロール判定ヘルパー関数
--   app_metadata のみを参照する（user_metadata は信頼しない）
-- ================================================================
CREATE OR REPLACE FUNCTION get_my_role()
RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT auth.jwt() -> 'app_metadata' ->> 'role'
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
-- 【確認クエリ】移行後に実行してロール設定を確認
-- ================================================================
-- SELECT email,
--        raw_app_meta_data  ->> 'role' AS app_role,
--        raw_user_meta_data ->> 'role' AS user_role
-- FROM auth.users
-- WHERE raw_app_meta_data  ->> 'role' IS NOT NULL
--    OR raw_user_meta_data ->> 'role' IS NOT NULL;
-- ================================================================
