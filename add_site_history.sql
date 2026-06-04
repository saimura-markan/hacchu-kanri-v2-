-- ================================================================
-- site_history テーブル作成 & RLS ポリシー設定
-- お客様が現場情報を変更・追加した際の履歴を記録する
-- Supabase ダッシュボード → SQL Editor で実行
-- ================================================================

CREATE TABLE IF NOT EXISTS public.site_history (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       text        NOT NULL,
  company_id     text,
  site_name      text,
  changed_by     text,
  field_name     text        NOT NULL,
  field_label    text        NOT NULL,
  old_value      text,
  new_value      text,
  seen_by_admin  boolean     NOT NULL DEFAULT false,
  changed_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS site_history_order_id_idx     ON public.site_history(order_id);
CREATE INDEX IF NOT EXISTS site_history_seen_by_admin_idx ON public.site_history(seen_by_admin);

ALTER TABLE public.site_history ENABLE ROW LEVEL SECURITY;

-- 認証済みユーザー全員が INSERT 可（お客様が現場情報を保存するとき）
CREATE POLICY "site_history_insert" ON public.site_history
  FOR INSERT TO authenticated
  WITH CHECK (true);

-- 認証済みユーザー全員が SELECT 可
CREATE POLICY "site_history_select" ON public.site_history
  FOR SELECT TO authenticated
  USING (true);

-- admin/manager/staff のみ UPDATE 可（管理者が既読マークをつけるとき）
CREATE POLICY "site_history_update_admin" ON public.site_history
  FOR UPDATE TO authenticated
  USING ((auth.jwt() -> 'app_metadata' ->> 'role') IN ('admin', 'manager', 'staff'));
