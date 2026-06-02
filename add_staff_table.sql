-- ================================================================
-- staffテーブル作成 & RLSポリシー設定
-- Supabase ダッシュボード → SQL Editor で実行
-- ================================================================

create table if not exists public.staff (
  id         uuid        primary key default gen_random_uuid(),
  name       text        not null,
  role       text        not null default 'staff'
               check (role in ('admin', 'manager', 'staff')),
  phone      text,
  email      text,
  is_active  boolean     not null default true,
  created_at timestamptz not null default now()
);

-- RLS 有効化
alter table public.staff enable row level security;

-- admin: 全データ読み書き可能
create policy "staff_admin_all" on public.staff
  for all
  to authenticated
  using  ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin')
  with check ((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin');

-- staff: 自分のメールに一致する行のみ読み取り可能
create policy "staff_self_select" on public.staff
  for select
  to authenticated
  using (
    (auth.jwt() -> 'app_metadata' ->> 'role') = 'staff'
    and email = auth.email()
  );
