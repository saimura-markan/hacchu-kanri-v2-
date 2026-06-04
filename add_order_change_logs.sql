-- ================================================================
-- order_change_logsテーブル作成 & RLSポリシー設定
-- お客様が現場情報を更新したとき記録し、管理者が確認できるようにする
-- Supabase ダッシュボード → SQL Editor で実行
-- ================================================================

create table if not exists public.order_change_logs (
  id           uuid        primary key default gen_random_uuid(),
  order_id     text        not null,
  changed_by   uuid        references auth.users(id) on delete set null,
  field_name   text        not null,
  old_value    text,
  new_value    text,
  confirmed_by uuid        references auth.users(id) on delete set null,
  confirmed_at timestamptz,
  changed_at   timestamptz not null default now()
);

create index if not exists order_change_logs_order_id_idx   on public.order_change_logs(order_id);
create index if not exists order_change_logs_confirmed_idx  on public.order_change_logs(confirmed_by);

alter table public.order_change_logs enable row level security;

-- お客様（user）: INSERT（自分が changed_by のレコードのみ）
create policy "order_change_logs_user_insert" on public.order_change_logs
  for insert to authenticated
  with check (changed_by = auth.uid());

-- admin/manager/staff: SELECT全件
create policy "order_change_logs_admin_select" on public.order_change_logs
  for select to authenticated
  using (true);

-- admin/manager: UPDATE（confirmed_by をセット）
create policy "order_change_logs_admin_update" on public.order_change_logs
  for update to authenticated
  using ((auth.jwt() -> 'app_metadata' ->> 'role') in ('admin', 'manager'))
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') in ('admin', 'manager'));
