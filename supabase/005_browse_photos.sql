-- _밑줄. 둘러보기에서 다른 사람이 공유한 밑줄 사진·표지가 안 보이던 문제 고치기
-- 원인: 사진 읽기 규칙이 pages/books 표를 확인하는데, 그 표는 각자 자기 것만 보이게 막혀 있어서
--       남의 공유 사진은 항상 '확인 안 됨'으로 거절되었습니다.
-- 고침: 공유 여부만 확인하는 작은 함수를 두고(남의 원본 사진은 여전히 못 봄), 규칙이 그 함수를 쓰게 합니다.
-- 여러 번 실행해도 안전합니다.

create index if not exists pages_share_path_idx on public.pages (share_path) where shared;

create or replace function public.is_shared_photo(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from pages p where p.shared and p.share_path = p_name)
      or exists (select 1 from books b
                  where b.cover_path = p_name
                    and exists (select 1 from pages p where p.book_id = b.id and p.shared and p.share_path is not null))
$$;
revoke all on function public.is_shared_photo(text) from public, anon;
grant execute on function public.is_shared_photo(text) to authenticated;

drop policy if exists "shared photos read" on storage.objects;
create policy "shared photos read" on storage.objects
  for select to authenticated using (bucket_id = 'photos' and public.is_shared_photo(name));
