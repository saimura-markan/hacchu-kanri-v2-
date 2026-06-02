-- ================================================================
-- status_logsテーブル作成 & RLSポリシー設定
-- Supabase ダッシュボード → SQL Editor で実行
-- ================================================================

create table if not exists public.status_logs (
  id          uuid        primary key default gen_random_uuid(),
  order_id    text        not null,
  changed_by  text        not null,
  old_status  text,
  new_status  text        not null,
  changed_at  timestamptz not null default now()
);

create index if not exists status_logs_order_id_idx on public.status_logs(order_id);

alter table public.status_logs enable row level security;

-- admin/manager/staff: SELECT可
create policy "status_logs_select" on public.status_logs
  for select to authenticated
  using (true);

-- admin/manager: INSERT可
create policy "status_logs_insert" on public.status_logs
  for insert to authenticated
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') in ('admin', 'manager'));
