-- Let's Walk — база данных
-- Вставь весь этот файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно: всё создаётся только если ещё не существует.

-- ============ 1. Профили ============
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default 'Гуляка' check (char_length(name) between 1 and 40),
  created_at timestamptz not null default now()
);

-- Профиль создаётся сам при регистрации; имя берётся из того, что человек ввёл при входе
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'Гуляка'))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ 2. Прогулки ============
create table if not exists public.walks (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  place        text not null check (char_length(place) between 1 and 90),
  lat          double precision not null check (lat between -90 and 90),
  lng          double precision not null check (lng between -180 and 180),
  start_at     timestamptz not null,
  duration_min int not null check (duration_min in (30, 45, 60, 90)),
  mood         text check (char_length(mood) <= 30),
  note         text check (char_length(note) <= 140),
  route        jsonb,
  created_at   timestamptz not null default now()
);
create index if not exists walks_start_at_idx on public.walks (start_at);

-- ============ 3. Участники ============
create table if not exists public.walk_participants (
  walk_id   uuid not null references public.walks(id) on delete cascade,
  user_id   uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (walk_id, user_id)
);

-- ============ 4. Защита от спама ============
-- Не больше 5 будущих прогулок у одного человека и не дальше чем на 14 дней вперёд
create or replace function public.check_walk_limits()
returns trigger language plpgsql as $$
begin
  if new.start_at > now() + interval '14 days' then
    raise exception 'Прогулку можно запланировать не дальше чем на 14 дней вперёд';
  end if;
  if new.start_at + make_interval(mins => new.duration_min) < now() then
    raise exception 'Это время уже прошло';
  end if;
  if (select count(*) from public.walks
      where author_id = new.author_id
        and start_at + make_interval(mins => duration_min) > now()) >= 5 then
    raise exception 'У тебя уже 5 запланированных прогулок';
  end if;
  return new;
end $$;

drop trigger if exists walks_limits on public.walks;
create trigger walks_limits
  before insert on public.walks
  for each row execute function public.check_walk_limits();

-- ============ 5. Правила доступа (Row Level Security) ============
alter table public.profiles          enable row level security;
alter table public.walks             enable row level security;
alter table public.walk_participants enable row level security;

-- Смотреть прогулки, участников и имена может любой, у кого есть ссылка
drop policy if exists "profiles readable"  on public.profiles;
drop policy if exists "walks readable"     on public.walks;
drop policy if exists "joins readable"     on public.walk_participants;
create policy "profiles readable" on public.profiles          for select using (true);
create policy "walks readable"    on public.walks             for select using (true);
create policy "joins readable"    on public.walk_participants for select using (true);

-- Менять своё имя может только сам человек
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Создавать прогулки можно только от своего имени, менять и удалять — только свои
drop policy if exists "walks insert own" on public.walks;
drop policy if exists "walks update own" on public.walks;
drop policy if exists "walks delete own" on public.walks;
create policy "walks insert own" on public.walks
  for insert to authenticated with check (author_id = auth.uid());
create policy "walks update own" on public.walks
  for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy "walks delete own" on public.walks
  for delete to authenticated using (author_id = auth.uid());

-- Присоединиться или выйти можно только за себя
drop policy if exists "joins insert own" on public.walk_participants;
drop policy if exists "joins delete own" on public.walk_participants;
create policy "joins insert own" on public.walk_participants
  for insert to authenticated with check (user_id = auth.uid());
create policy "joins delete own" on public.walk_participants
  for delete to authenticated using (user_id = auth.uid());

-- ============ 6. Обновления в реальном времени ============
do $$
begin
  begin alter publication supabase_realtime add table public.walks;             exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.walk_participants; exception when duplicate_object then null; end;
end $$;
