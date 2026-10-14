-- Let's Walk — задания прогулки
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.

-- Какое задание выбрано (номер меняется кнопкой «Другое задание») и выполнено ли оно
alter table public.walks add column if not exists task_seed    int not null default 0;
alter table public.walks add column if not exists task_done_at timestamptz;
alter table public.walks add column if not exists task_done_by uuid references public.profiles(id) on delete set null;

-- Когда автор меняет задание, отметка «выполнено» сбрасывается
create or replace function public.reset_task_done()
returns trigger language plpgsql as $$
begin
  if new.task_seed is distinct from old.task_seed then
    new.task_done_at := null;
    new.task_done_by := null;
  end if;
  return new;
end $$;
drop trigger if exists walks_reset_task on public.walks;
create trigger walks_reset_task
  before update on public.walks
  for each row execute function public.reset_task_done();

-- «Выполнили!» может нажать любой участник прогулки (автор или тот, кто нажал «Я с вами»)
create or replace function public.mark_task_done(w uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_walk_member(w) then
    raise exception 'Отметить задание могут только участники прогулки';
  end if;
  update public.walks
     set task_done_at = now(), task_done_by = auth.uid()
   where id = w and task_done_at is null;
end $$;
revoke all on function public.mark_task_done(uuid) from public;
grant execute on function public.mark_task_done(uuid) to authenticated;
