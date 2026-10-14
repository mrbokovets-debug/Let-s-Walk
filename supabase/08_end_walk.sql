-- Let's Walk — завершение прогулки
-- Автор завершает прогулку кнопкой; без этого она завершается сама через 3 часа после начала.
-- Запускать можно повторно.

alter table public.walks add column if not exists ended_at timestamptz;

-- «Завершить прогулку»: только автор и только после начала (допуск 5 минут)
create or replace function public.end_walk(w uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.walks
     set ended_at = now()
   where id = w
     and author_id = auth.uid()
     and ended_at is null
     and start_at <= now() + interval '5 minutes';
  if not found then
    raise exception 'Завершить прогулку может только её автор после начала';
  end if;
end $$;
revoke all on function public.end_walk(uuid) from public;
grant execute on function public.end_walk(uuid) to authenticated;

-- К завершённой прогулке нельзя присоединиться
drop policy if exists "joins insert own" on public.walk_participants;
create policy "joins insert own" on public.walk_participants
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and not exists (select 1 from public.walks w where w.id = walk_id and w.ended_at is not null)
  );

-- «Выполнили!»: с начала прогулки и до 30 минут после её завершения (или 3 часов после начала)
create or replace function public.mark_task_done(w uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  s timestamptz; e timestamptz;
begin
  if not public.is_walk_member(w) then
    raise exception 'Отметить задание могут только участники прогулки';
  end if;
  select start_at, ended_at into s, e from public.walks where id = w;
  if s is null then
    raise exception 'Прогулка не найдена';
  end if;
  if now() < s then
    raise exception 'Отметить задание можно, когда начнётся прогулка';
  end if;
  if now() > coalesce(e, s + interval '3 hours') + interval '30 minutes' then
    raise exception 'Прогулка уже закончилась';
  end if;
  update public.walks
     set task_done_at = now(), task_done_by = auth.uid()
   where id = w and task_done_at is null;
end $$;
revoke all on function public.mark_task_done(uuid) from public;
grant execute on function public.mark_task_done(uuid) to authenticated;
