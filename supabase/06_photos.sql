-- Let's Walk — фото в чате прогулки
-- Вставь весь файл в Supabase → SQL Editor → New query и нажми Run.
-- Запускать можно повторно.

-- ============ 1. Хранилище для фото ============
-- Закрытое: фото видят только участники прогулки. Не больше 2 МБ, только картинки.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('walk-photos', 'walk-photos', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- Путь файла: <id прогулки>/<id автора фото>/<имя>.jpg
drop policy if exists "walk photos read by members"   on storage.objects;
drop policy if exists "walk photos upload by members" on storage.objects;
drop policy if exists "walk photos delete own"        on storage.objects;

create policy "walk photos read by members" on storage.objects
  for select to authenticated
  using (bucket_id = 'walk-photos'
         and public.is_walk_member(((storage.foldername(name))[1])::uuid));

create policy "walk photos upload by members" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'walk-photos'
              and (storage.foldername(name))[2] = auth.uid()::text
              and public.is_walk_member(((storage.foldername(name))[1])::uuid));

create policy "walk photos delete own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'walk-photos'
         and (storage.foldername(name))[2] = auth.uid()::text);

-- ============ 2. Сообщение может быть фото ============
alter table public.walk_messages add column if not exists photo_path text;

-- Текст теперь может быть пустым, если есть фото; фото должно лежать в папке своей прогулки
alter table public.walk_messages drop constraint if exists walk_messages_body_check;
alter table public.walk_messages drop constraint if exists walk_messages_content_check;
alter table public.walk_messages add constraint walk_messages_content_check check (
  char_length(body) <= 500
  and (char_length(btrim(body)) >= 1 or photo_path is not null)
  and (photo_path is null or photo_path like walk_id::text || '/%')
);
