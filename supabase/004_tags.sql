-- _밑줄. 밑줄에 태그 달기 (본인만 보는 정리용, 공유되지 않음)
-- 여러 번 실행해도 안전합니다.
alter table public.pages add column if not exists tags text[] not null default '{}';
