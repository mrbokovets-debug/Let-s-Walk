-- Let's Walk — чат внутри прогулки
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.

create table if not exists public.walk_messages (
  id         bigint generated always as identity primary key,
  walk_id    uuid not null references public.walks(id) on delete cascade,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists walk_messages_walk_idx on public.walk_messages (walk_id, created_at);

-- Участник прогулки = её автор или тот, кто нажал «Я с вами»
create or replace function public.is_walk_member(w uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.walks where id = w and author_id = auth.uid())
      or exists (select 1 from public.walk_participants where walk_id = w and user_id = auth.uid());
$$;
revoke all on function public.is_walk_member(uuid) from public;
grant execute on function public.is_walk_member(uuid) to authenticated;

-- Защита от спама: не больше 20 сообщений в минуту от одного человека
create or replace function public.check_message_rate()
returns trigger language plpgsql as $$
begin
  if (select count(*) from public.walk_messages
      where user_id = new.user_id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Слишком много сообщений. Подожди минутку';
  end if;
  return new;
end $$;
drop trigger if exists walk_messages_rate on public.walk_messages;
create trigger walk_messages_rate
  before insert on public.walk_messages
  for each row execute function public.check_message_rate();

-- Правила доступа: читать и писать могут только участники прогулки
alter table public.walk_messages enable row level security;
drop policy if exists "messages read by members"   on public.walk_messages;
drop policy if exists "messages insert by members" on public.walk_messages;
drop policy if exists "messages delete own"        on public.walk_messages;
create policy "messages read by members" on public.walk_messages
  for select to authenticated using (public.is_walk_member(walk_id));
create policy "messages insert by members" on public.walk_messages
  for insert to authenticated with check (user_id = auth.uid() and public.is_walk_member(walk_id));
create policy "messages delete own" on public.walk_messages
  for delete to authenticated using (user_id = auth.uid());

-- Сообщения приходят сразу, без обновления страницы
do $$
begin
  begin alter publication supabase_realtime add table public.walk_messages; exception when duplicate_object then null; end;
end $$;
