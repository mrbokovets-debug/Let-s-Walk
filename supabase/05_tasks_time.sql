-- Let's Walk — задание можно отметить только во время прогулки, и отметку можно снять
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.

-- «Выполнили!»: только участники и только с начала прогулки до часа после её конца
create or replace function public.mark_task_done(w uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  s timestamptz; d int;
begin
  if not public.is_walk_member(w) then
    raise exception 'Отметить задание могут только участники прогулки';
  end if;
  select start_at, duration_min into s, d from public.walks where id = w;
  if s is null then
    raise exception 'Прогулка не найдена';
  end if;
  if now() < s then
    raise exception 'Отметить задание можно, когда начнётся прогулка';
  end if;
  if now() > s + make_interval(mins => d) + interval '1 hour' then
    raise exception 'Прогулка уже закончилась';
  end if;
  update public.walks
     set task_done_at = now(), task_done_by = auth.uid()
   where id = w and task_done_at is null;
end $$;
revoke all on function public.mark_task_done(uuid) from public;
grant execute on function public.mark_task_done(uuid) to authenticated;

-- «Снять отметку»: тот, кто отметил, или автор прогулки
create or replace function public.unmark_task_done(w uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.walks
     set task_done_at = null, task_done_by = null
   where id = w
     and (task_done_by = auth.uid() or author_id = auth.uid());
end $$;
revoke all on function public.unmark_task_done(uuid) from public;
grant execute on function public.unmark_task_done(uuid) to authenticated;
