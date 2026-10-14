-- Let's Walk — безопасность: жалобы и скрытие людей
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.

-- ============ 1. Скрытые прогулки ============
alter table public.walks add column if not exists hidden boolean not null default false;

-- Скрытую прогулку видит только её автор
drop policy if exists "walks readable" on public.walks;
create policy "walks readable" on public.walks
  for select using (not hidden or author_id = auth.uid());

-- ============ 2. Жалобы ============
create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  reporter_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  target_user uuid not null references public.profiles(id) on delete cascade,
  walk_id     uuid references public.walks(id) on delete set null,
  message_id  bigint references public.walk_messages(id) on delete set null,
  reason      text not null check (reason in ('spam','abuse','danger','fake','other')),
  details     text check (char_length(details) <= 300),
  status      text not null default 'new' check (status in ('new','reviewed','dismissed')),
  created_at  timestamptz not null default now(),
  check (reporter_id <> target_user)
);
create index if not exists reports_walk_idx on public.reports (walk_id);
create index if not exists reports_target_idx on public.reports (target_user);

-- Не больше 10 жалоб в сутки от одного человека
create or replace function public.check_report_rate()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.reports
      where reporter_id = new.reporter_id and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Слишком много жалоб за сутки. Попробуй завтра';
  end if;
  return new;
end $$;
drop trigger if exists reports_rate on public.reports;
create trigger reports_rate
  before insert on public.reports
  for each row execute function public.check_report_rate();

-- Если на прогулку пожаловались 3 разных человека, она скрывается с карты
create or replace function public.auto_hide_reported_walk()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.walk_id is not null and
     (select count(distinct reporter_id) from public.reports where walk_id = new.walk_id) >= 3 then
    update public.walks set hidden = true where id = new.walk_id;
  end if;
  return new;
end $$;
drop trigger if exists reports_auto_hide on public.reports;
create trigger reports_auto_hide
  after insert on public.reports
  for each row execute function public.auto_hide_reported_walk();

alter table public.reports enable row level security;
drop policy if exists "reports insert own" on public.reports;
drop policy if exists "reports read own"   on public.reports;
create policy "reports insert own" on public.reports
  for insert to authenticated with check (reporter_id = auth.uid());
create policy "reports read own" on public.reports
  for select to authenticated using (reporter_id = auth.uid());
-- Все жалобы видишь ты: Supabase → Table Editor → reports

-- ============ 3. Скрытые люди ============
create table if not exists public.blocks (
  blocker_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;
drop policy if exists "blocks read own"   on public.blocks;
drop policy if exists "blocks insert own" on public.blocks;
drop policy if exists "blocks delete own" on public.blocks;
create policy "blocks read own"   on public.blocks for select to authenticated using (blocker_id = auth.uid());
create policy "blocks insert own" on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
create policy "blocks delete own" on public.blocks for delete to authenticated using (blocker_id = auth.uid());
