-- Let's Walk — push-уведомления
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.
-- Секретный ключ сюда НЕ пишется: его добавляют отдельной командой (см. инструкцию в чате).

create extension if not exists pg_net with schema extensions;

-- ============ 1. Подписки телефонов на уведомления ============
create table if not exists public.push_subscriptions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "push read own"   on public.push_subscriptions;
drop policy if exists "push insert own" on public.push_subscriptions;
drop policy if exists "push update own" on public.push_subscriptions;
drop policy if exists "push delete own" on public.push_subscriptions;
create policy "push read own"   on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
create policy "push insert own" on public.push_subscriptions for insert to authenticated with check (user_id = auth.uid());
create policy "push update own" on public.push_subscriptions for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "push delete own" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- ============ 2. Закрытые настройки (не видны через приложение) ============
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.config (key text primary key, value text not null);

-- ============ 3. Отправка события в функцию notify ============
create or replace function private.send_push_event(payload jsonb)
returns void language plpgsql security definer set search_path = public, private, extensions as $$
declare
  secret text;
begin
  select value into secret from private.config where key = 'notify_secret';
  if secret is null then return; end if;  -- уведомления ещё не настроены
  perform net.http_post(
    url     := 'https://fweicomizgndbxdoxovn.supabase.co/functions/v1/notify',
    headers := jsonb_build_object('Content-Type','application/json','x-notify-secret',secret),
    body    := payload
  );
end $$;

-- Новое сообщение в чате
create or replace function private.on_message_push()
returns trigger language plpgsql security definer set search_path = public, private as $$
begin
  perform private.send_push_event(jsonb_build_object(
    'type','message','walk_id',new.walk_id,'user_id',new.user_id,
    'body',new.body,'has_photo',(to_jsonb(new) ? 'photo_path') and (to_jsonb(new)->>'photo_path') is not null));
  return new;
end $$;
drop trigger if exists walk_messages_push on public.walk_messages;
create trigger walk_messages_push after insert on public.walk_messages
  for each row execute function private.on_message_push();

-- Кто-то присоединился
create or replace function private.on_join_push()
returns trigger language plpgsql security definer set search_path = public, private as $$
begin
  perform private.send_push_event(jsonb_build_object('type','join','walk_id',new.walk_id,'user_id',new.user_id));
  return new;
end $$;
drop trigger if exists walk_participants_push on public.walk_participants;
create trigger walk_participants_push after insert on public.walk_participants
  for each row execute function private.on_join_push();

-- Прогулку отменили (участников запоминаем до удаления)
create or replace function private.on_cancel_push()
returns trigger language plpgsql security definer set search_path = public, private as $$
declare
  ids uuid[];
begin
  select coalesce(array_agg(user_id), '{}') into ids
    from public.walk_participants where walk_id = old.id and user_id <> old.author_id;
  if array_length(ids, 1) > 0 then
    perform private.send_push_event(jsonb_build_object(
      'type','cancel','walk_id',old.id,'user_id',old.author_id,
      'place',old.place,'start_at',old.start_at,'recipients',to_jsonb(ids)));
  end if;
  return old;
end $$;
drop trigger if exists walks_cancel_push on public.walks;
create trigger walks_cancel_push before delete on public.walks
  for each row execute function private.on_cancel_push();
