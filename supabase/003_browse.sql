-- _밑줄. 둘러보기: 공유를 켠 밑줄이 있는 책을 다른 사람도 볼 수 있게
-- Supabase 대시보드 → SQL Editor → New query 에 붙여 넣고 Run. 여러 번 실행해도 안전합니다.
-- 보이는 것(로그인한 사람에게만): 공유를 켠 밑줄이 있는 책의 제목·저자·표지·이름,
--   공유를 켠 밑줄의 '형광펜 부분만 잘라 만든 공유용 사진'·메모·쪽수·날짜. 한 책에 무작위 10개까지.
-- 보이지 않는 것: 원본 페이지 사진, 공유를 켜지 않은 밑줄, 다른 책.

alter table public.pages add column if not exists share_path text;

-- 1) 공유 조건 완화: 메모가 없어도 공유할 수 있고, 개수 제한 오류도 없앱니다 (보여 줄 때 10개로 제한)
drop trigger if exists pages_check_share on public.pages;

-- 2) 둘러보기 책 목록 (내 책 제외, 공유한 밑줄이 있는 책만, 최근 활동순)
create or replace function public.browse_books() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then return '[]'::json; end if;
  return coalesce((
    select json_agg(x order by x.active_at desc)
    from (
      select b.id, b.title, b.author, b.cover_path,
             coalesce(nullif(pr.username, ''), '익명의 독자') as name,
             greatest(b.created_at, coalesce(max(p.created_at), 0)) as active_at,
             count(p.id) as shared
      from books b
      join pages p on p.book_id = b.id and p.shared and p.share_path is not null
      left join profiles pr on pr.id = b.user_id
      where b.user_id <> auth.uid()
      group by b.id, pr.username
      limit 200
    ) x
  ), '[]'::json);
end $$;
revoke all on function public.browse_books() from public, anon;
grant execute on function public.browse_books() to authenticated;

-- 3) 한 권에서 공유한 밑줄 (무작위 10개)
create or replace function public.browse_book_notes(p_book uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare
  bk record;
begin
  if auth.uid() is null then return null; end if;
  select b.id, b.title, b.author, b.cover_path, b.user_id, coalesce(nullif(pr.username, ''), '익명의 독자') as name
    into bk
    from books b left join profiles pr on pr.id = b.user_id
   where b.id = p_book and exists (select 1 from pages p where p.book_id = b.id and p.shared and p.share_path is not null);
  if bk.id is null then return null; end if;
  return json_build_object(
    'id', bk.id, 'title', bk.title, 'author', bk.author, 'cover_path', bk.cover_path, 'name', bk.name,
    'mine', bk.user_id = auth.uid(),
    'total', (select count(*) from pages p where p.book_id = bk.id and p.shared and p.share_path is not null),
    'notes', coalesce((
      select json_agg(x)
      from (
        select p.id, p.note, p.page_no, p.created_at, p.share_path,
               coalesce(p.strokes -> 0 ->> 'c', 'y') as color
        from pages p
        where p.book_id = bk.id and p.shared and p.share_path is not null
        order by random()
        limit 10
      ) x
    ), '[]'::json)
  );
end $$;
revoke all on function public.browse_book_notes(uuid) from public, anon;
grant execute on function public.browse_book_notes(uuid) to authenticated;

-- 4) '같이 읽은 사람들'도 밑줄 사진과 형광펜을 함께 (메모 없는 공유 포함)
create or replace function public.shared_for_book(p_book uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare
  k text;
begin
  if auth.uid() is null then return json_build_object('readers', 0, 'items', '[]'::json); end if;
  select title_key into k from books where id = p_book and user_id = auth.uid();
  if coalesce(k, '') = '' then return json_build_object('readers', 0, 'items', '[]'::json); end if;
  return json_build_object(
    'readers', (select count(distinct b.user_id) from books b where same_book(b.title_key, k)),
    'items', coalesce((
      select json_agg(x order by x.sort_no nulls last, x.created_at)
      from (
        select p.id, p.note, p.page_no, p.share_path,
               nullif(regexp_replace(p.page_no, '[^0-9]', '', 'g'), '')::int as sort_no,
               coalesce(nullif(pr.username, ''), '익명의 독자') as name,
               p.created_at, b.title, b.author,
               (p.user_id = auth.uid()) as mine
        from pages p
        join books b on b.id = p.book_id
        left join profiles pr on pr.id = p.user_id
        where p.shared and p.share_path is not null and same_book(b.title_key, k)
      ) x
    ), '[]'::json)
  );
end $$;
revoke all on function public.shared_for_book(uuid) from public, anon;
grant execute on function public.shared_for_book(uuid) to authenticated;

-- 5) 사진 보관함: 로그인한 사람은 '공유용으로 잘라 둔 사진'과 '그 책의 표지'만 추가로 읽을 수 있음 (원본 페이지 사진은 불가)
drop policy if exists "public covers read" on storage.objects;
drop policy if exists "shared photos read" on storage.objects;
create policy "shared photos read" on storage.objects
  for select to authenticated using (
    bucket_id = 'photos' and (
      exists (select 1 from public.pages p where p.shared and p.share_path = storage.objects.name)
      or exists (select 1 from public.books b where b.cover_path = storage.objects.name
                   and exists (select 1 from public.pages p where p.book_id = b.id and p.shared and p.share_path is not null))
    )
  );
