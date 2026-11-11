-- _밑줄. 같은 책 독자끼리 밑줄 공유
-- Supabase 대시보드 → SQL Editor → New query 에 전체를 붙여 넣고 Run.
-- 여러 번 실행해도 안전합니다.

-- 비슷한 제목(오타 1~2자)을 찾는 데 씁니다. 한글에서도 글자 단위로 동작합니다.
create extension if not exists fuzzystrmatch;

-- 1) 같은 책 묶기 ----------------------------------------------------------

alter table public.books add column if not exists author text not null default '';
alter table public.books add column if not exists title_key text not null default '';
create index if not exists books_title_key_idx on public.books (title_key);

-- 제목을 비교용 열쇠로: 부제·괄호·판 표기·공백·문장부호를 떼고 소문자로
create or replace function public.norm_title(t text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(
                 lower(coalesce(t, '')),
                 '[\(\[\{（【〔].*?[\)\]\}）】〕]', '', 'g'),          -- 괄호 안 부제
               '\s*([:：]|\s[-–—]\s|[–—]).*$', ''),                     -- 콜론·대시 뒤 부제
             '(개정증보판|개정판|증보판|리커버|특별판|한정판|기념판|양장본|보급판|리마스터|장편소설|단편소설|소설집|에디션|edition)', '', 'g'),
           '[^0-9a-z가-힣ㄱ-ㅎぁ-んァ-ン一-龥]', '', 'g')               -- 공백·문장부호·따옴표
$$;

create or replace function public.books_set_title_key() returns trigger
language plpgsql as $$
begin
  new.title_key := public.norm_title(new.title);
  return new;
end $$;

drop trigger if exists books_title_key on public.books;
create trigger books_title_key before insert or update of title on public.books
  for each row execute function public.books_set_title_key();

update public.books set title_key = public.norm_title(title) where title_key is distinct from public.norm_title(title);

-- 두 열쇠가 같은 책인지: 완전 일치, 또는 4자 이상이면 오타 1자(8자 이상은 2자)까지
create or replace function public.same_book(a text, b text) returns boolean
language sql immutable as $$
  select case
    when coalesce(a, '') = '' or coalesce(b, '') = '' then false
    when a = b then true
    when char_length(a) <= 3 or char_length(b) <= 3 then false
    when abs(char_length(a) - char_length(b)) > 2 then false
    else levenshtein(a, b) <= case when least(char_length(a), char_length(b)) >= 8 then 2 else 1 end
  end
$$;

-- 2) 공유 규칙 -------------------------------------------------------------

alter table public.pages add column if not exists shared boolean not null default false;
create index if not exists pages_shared_idx on public.pages (book_id) where shared;

-- 메모가 있어야 공유, 한 사람당 한 책 최대 10개
create or replace function public.pages_check_share() returns trigger
language plpgsql as $$
begin
  if new.shared then
    if coalesce(btrim(new.note), '') = '' then
      raise exception 'share_needs_note' using errcode = 'P0001';
    end if;
    if (select count(*) from public.pages p
         where p.user_id = new.user_id and p.book_id = new.book_id and p.shared and p.id <> new.id) >= 10 then
      raise exception 'share_limit' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists pages_check_share on public.pages;
create trigger pages_check_share before insert or update of shared, note on public.pages
  for each row execute function public.pages_check_share();

-- 이름 (공유 카드에 표시)
create table if not exists public.profiles (
  id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  username text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- 신고
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references public.pages (id) on delete cascade,
  reporter uuid not null default auth.uid() references auth.users (id) on delete cascade,
  reason text not null default '',
  created_at timestamptz not null default now(),
  unique (page_id, reporter)
);
alter table public.reports enable row level security;
drop policy if exists "own reports" on public.reports;
create policy "own reports" on public.reports
  for all using (reporter = auth.uid()) with check (reporter = auth.uid());

-- 3) 같이 읽은 사람들 (공유 범위를 서버에서만 정함) ---------------------------
-- 페이지 사진, 표지, 그은 선, 사진 경로는 내보내지 않습니다.
-- 인용은 150자까지, 신고 3건 이상이면 숨김.

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
        select p.id,
               case when char_length(p.quote) > 150 then left(p.quote, 150) || '…' else p.quote end as quote,
               p.note,
               p.page_no,
               nullif(regexp_replace(p.page_no, '[^0-9]', '', 'g'), '')::int as sort_no,
               coalesce(nullif(pr.username, ''), '익명의 독자') as name,
               p.created_at,
               b.title,
               b.author,
               (p.user_id = auth.uid()) as mine
        from pages p
        join books b on b.id = p.book_id
        left join profiles pr on pr.id = p.user_id
        where p.shared
          and same_book(b.title_key, k)
          and (select count(*) from reports r where r.page_id = p.id) < 3
          and not exists (select 1 from reports r where r.page_id = p.id and r.reporter = auth.uid())
      ) x
    ), '[]'::json)
  );
end $$;

revoke all on function public.shared_for_book(uuid) from public, anon;
grant execute on function public.shared_for_book(uuid) to authenticated;

-- 공유된 밑줄만, 남의 것만 신고할 수 있게
create or replace function public.report_page(p_page uuid, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from pages where id = p_page and shared and user_id <> auth.uid()) then
    raise exception 'cannot_report';
  end if;
  insert into reports (page_id, reporter, reason) values (p_page, auth.uid(), left(coalesce(p_reason, ''), 300))
  on conflict (page_id, reporter) do nothing;
end $$;

revoke all on function public.report_page(uuid, text) from public, anon;
grant execute on function public.report_page(uuid, text) to authenticated;
