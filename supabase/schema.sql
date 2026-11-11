-- _밑줄. Supabase 설정
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run 을 누르세요.

-- 책
create table if not exists public.books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title text not null default '',
  cover_path text,
  ocr text,
  created_at bigint not null default (extract(epoch from now()) * 1000)::bigint
);

-- 밑줄 페이지
create table if not exists public.pages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  book_id uuid not null references public.books (id) on delete cascade,
  image_path text,
  w int,
  h int,
  strokes jsonb not null default '[]'::jsonb,
  page_no text not null default '',
  quote text not null default '',
  note text not null default '',
  ocr text,
  created_at bigint not null default (extract(epoch from now()) * 1000)::bigint,
  updated_at bigint
);

create index if not exists pages_book_id_idx on public.pages (book_id);
create index if not exists books_user_id_idx on public.books (user_id);
create index if not exists pages_user_id_idx on public.pages (user_id);

-- 각자 자기 기록만 보고 고칠 수 있게
alter table public.books enable row level security;
alter table public.pages enable row level security;

drop policy if exists "own books" on public.books;
create policy "own books" on public.books
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own pages" on public.pages;
create policy "own pages" on public.pages
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 사진 보관함 (비공개). 경로는 "<user id>/<파일 이름>"
insert into storage.buckets (id, name, public)
values ('photos', 'photos', false)
on conflict (id) do nothing;

drop policy if exists "own photos read" on storage.objects;
create policy "own photos read" on storage.objects
  for select using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own photos write" on storage.objects;
create policy "own photos write" on storage.objects
  for insert with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own photos delete" on storage.objects;
create policy "own photos delete" on storage.objects
  for delete using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
