-- Server timestamps; historical start times remain unknown.
create table app_private.inspection_runs (
 user_id uuid not null references public.profiles(id),
 request_key uuid not null,
 branch_id integer not null references public.branches(id),
 started_at timestamptz not null default now(),
 primary key(user_id,request_key)
);
alter table app_private.inspection_runs enable row level security;
revoke all on app_private.inspection_runs from public,anon,authenticated;
alter table public.inspections add column started_at timestamptz;
alter table public.inspections add constraint inspection_time_order check(started_at is null or started_at<=created_at);
alter table public.inspections add column duration_seconds integer generated always as (case when started_at is null then null else floor(extract(epoch from (created_at-started_at)))::integer end) stored;
create or replace function app_private.report_data(p_from date,p_to date,p_branch integer,p_export boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_from>p_to then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.';end if;
 if p_export then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into result from (
   select i.id,i.created_at,i.started_at,i.duration_seconds,i.branch_name,i.user_name,a.question_text,a.rating,i.note
   from public.inspections i join public.answers a on a.inspection_id=i.id
   where (p_from is null or i.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi'))
    and (p_to is null or i.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))
    and (p_branch is null or i.branch_id=p_branch)
   order by i.created_at desc,a.id limit 50001
  ) x;
  if jsonb_array_length(result)>50000 then raise exception 'ექსპორტისთვის შეამცირეთ პერიოდი (მაქსიმუმ 50 000 პასუხი).';end if;
  return result;
 end if;
 with filtered as (
  select i.* from public.inspections i
  where (p_from is null or i.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi'))
   and (p_to is null or i.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (p_branch is null or i.branch_id=p_branch)
 ), scores as (
  select i.*,round(avg(a.rating),2) score,count(a.id) answer_count from filtered i join public.answers a on a.inspection_id=i.id group by i.id,i.branch_id,i.branch_name,i.user_id,i.user_name,i.created_at,i.note,i.request_key,i.started_at,i.duration_seconds
 ), latest as (select * from scores order by created_at desc,id desc limit 200),
 stats as (select count(a.id) answers,round(avg(a.rating),2) score,count(*) filter(where a.rating<=2) issues from filtered i join public.answers a on a.inspection_id=i.id),
 bybranch as (select i.branch_id,i.branch_name,round(avg(a.rating),2) score,count(distinct i.id) inspections,count(*) filter(where a.rating<=2) issues from filtered i join public.answers a on a.inspection_id=i.id group by i.branch_id,i.branch_name order by score desc,branch_name)
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(latest) order by created_at desc,id desc) from latest),'[]'::jsonb),'stats',(select to_jsonb(stats) from stats),'byBranch',coalesce((select jsonb_agg(to_jsonb(bybranch) order by score desc,branch_name) from bybranch),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.report_data(date,date,integer,boolean) from public,anon,authenticated;


do $migration$
declare definition text;
begin
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,$old$ if route='/inspections' and method='POST' then$old$,$new$
 if route='/inspections/start' and method='POST' then
  if not exists(select 1 from public.branches where id=(payload->>'branch_id')::integer and active) then raise exception 'აირჩიეთ მოქმედი ფილიალი.';end if;
  insert into app_private.inspection_runs(user_id,request_key,branch_id) values(actor.id,(payload->>'request_key')::uuid,(payload->>'branch_id')::integer) on conflict do nothing;
  select to_jsonb(r) into result from app_private.inspection_runs r where r.user_id=actor.id and r.request_key=(payload->>'request_key')::uuid and r.branch_id=(payload->>'branch_id')::integer;
  if result is null then raise exception 'დაწყებული შემოწმების ფილიალი განსხვავდება.';end if;
  return jsonb_build_object('started_at',result->'started_at');
 end if;
 if route='/inspections' and method='POST' then$new$);
 definition=replace(definition,$old$insert into public.inspections(branch_id,branch_name,user_id,user_name,note,request_key) values(branch.id,branch.name,actor.id,actor.name,payload->>'note',(payload->>'request_key')::uuid)$old$,$new$insert into public.inspections(branch_id,branch_name,user_id,user_name,note,request_key,started_at) values(branch.id,branch.name,actor.id,actor.name,payload->>'note',(payload->>'request_key')::uuid,(select r.started_at from app_private.inspection_runs r where r.user_id=actor.id and r.request_key=(payload->>'request_key')::uuid and r.branch_id=branch.id))$new$);
 definition=replace(definition,$old$ if route in ('/reports','/export')$old$,$new$
 if route='/issues' and method='GET' then
  if nullif(payload->>'from','')::date > nullif(payload->>'to','')::date then raise exception 'შეამოწმეთ თარიღების პერიოდი.';end if;
  with matching as (
   select a.id answer_id,i.id inspection_id,i.branch_name,i.user_name,i.created_at,a.question_text,a.rating,i.note
   from public.inspections i join public.answers a on a.inspection_id=i.id
   where a.rating<=2
    and (nullif(payload->>'from','') is null or i.created_at >= (nullif(payload->>'from','')::date::timestamp at time zone 'Asia/Tbilisi'))
    and (nullif(payload->>'to','') is null or i.created_at < ((nullif(payload->>'to','')::date+1)::timestamp at time zone 'Asia/Tbilisi'))
    and (nullif(payload->>'branch','') is null or i.branch_id=(payload->>'branch')::integer)
  ), paged as (select * from matching order by rating,created_at desc,answer_id desc limit 100 offset greatest(0,coalesce((payload->>'page')::integer,0))*100)
  select jsonb_build_object('total',(select count(*) from matching),'rows',coalesce((select jsonb_agg(to_jsonb(paged) order by rating,created_at desc,answer_id desc) from paged),'[]'::jsonb)) into result;
  return result;
 end if;
 if route in ('/reports','/export')$new$);
 execute definition;
end $migration$;
