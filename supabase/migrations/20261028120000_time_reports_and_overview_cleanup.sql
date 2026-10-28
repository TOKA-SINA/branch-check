create table if not exists public.supervisor_branch_time (
 id bigint generated always as identity primary key,
 branch_id integer not null references public.branches(id),
 supervisor_user_id uuid not null references public.profiles(id),
 supervisor_name text not null,
 entry_at timestamptz not null,
 exit_at timestamptz,
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint supervisor_branch_time_exit_after_entry check (exit_at is null or exit_at >= entry_at)
);
create index if not exists supervisor_branch_time_entry_idx on public.supervisor_branch_time(entry_at,branch_id);
alter table public.supervisor_branch_time enable row level security;
revoke all on public.supervisor_branch_time from public,anon,authenticated;

create or replace function public.supervisor_time_api(route text, method text default 'GET', payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to public, app_private as $$
declare
 actor public.profiles%rowtype;
 item public.supervisor_branch_time%rowtype;
 branch public.branches%rowtype;
 supervisor public.profiles%rowtype;
 match text[];
 entry_value timestamptz;
 exit_value timestamptz;
 from_date date;
 to_date date;
 sort_value text:=coalesce(nullif(payload->>'sort',''),'desc');
 result jsonb;
begin
 select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null;
 if actor.id is null then raise exception 'გთხოვთ შეხვიდეთ სისტემაში.' using errcode='42501'; end if;
 if actor.role not in ('admin','monitoring') then raise exception 'წვდომა შეზღუდულია.' using errcode='42501'; end if;

 if route='/supervisor-time' and method='GET' then
  return jsonb_build_object(
   'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.entry_at desc,x.id desc) from (
    select t.id,t.branch_id,b.name branch_name,t.supervisor_user_id,t.supervisor_name,t.entry_at,t.exit_at,
     greatest(0,extract(epoch from (coalesce(t.exit_at,now())-t.entry_at)))::bigint duration_seconds,
     t.recorded_by,t.created_at,t.updated_at
    from public.supervisor_branch_time t join public.branches b on b.id=t.branch_id
    where (actor.role='admin' or (t.entry_at at time zone 'Asia/Tbilisi')::date=(now() at time zone 'Asia/Tbilisi')::date)
   ) x),'[]'::jsonb)
  );
 end if;

 if route='/supervisor-time/report' and method='GET' then
  if actor.role<>'admin' then raise exception 'რეპორტი მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
  from_date:=nullif(payload->>'from','')::date; to_date:=nullif(payload->>'to','')::date;
  if from_date is not null and to_date is not null and from_date>to_date then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.'; end if;
  if sort_value not in ('asc','desc') then raise exception 'არასწორი დალაგება.'; end if;
  with grouped as (
   select t.branch_id,b.name branch_name,t.supervisor_user_id,t.supervisor_name,count(*)::integer records,
    round(sum(greatest(0,extract(epoch from (coalesce(t.exit_at,now())-t.entry_at))))::numeric,0)::bigint total_seconds,
    min(t.entry_at) first_entry_at,max(t.exit_at) last_exit_at
   from public.supervisor_branch_time t join public.branches b on b.id=t.branch_id
   where (from_date is null or t.entry_at >= (from_date::timestamp at time zone 'Asia/Tbilisi'))
    and (to_date is null or t.entry_at < ((to_date+1)::timestamp at time zone 'Asia/Tbilisi'))
    and (nullif(payload->>'branch','') is null or t.branch_id=(payload->>'branch')::integer)
   group by t.branch_id,b.name,t.supervisor_user_id,t.supervisor_name
  )
  select jsonb_build_object('from',from_date,'to',to_date,'sort',sort_value,'rows',coalesce((select jsonb_agg(to_jsonb(g) order by case when sort_value='asc' then total_seconds end asc,case when sort_value='desc' then total_seconds end desc,branch_name) from grouped),'[]'::jsonb)) into result;
  return result;
 end if;

 if route='/supervisor-time' and method='POST' then
  if jsonb_typeof(payload->'branch_id') is distinct from 'number' then raise exception 'აირჩიეთ ფილიალი.'; end if;
  entry_value:=coalesce(nullif(payload->>'entry_at','')::timestamptz,now());
  exit_value:=nullif(payload->>'exit_at','')::timestamptz;
  if exit_value is not null and exit_value<entry_value then raise exception 'გასვლის დრო შესვლის დროზე ადრე ვერ იქნება.'; end if;
  select * into branch from public.branches where id=(payload->>'branch_id')::integer and active;
  if branch.id is null then raise exception 'აირჩიეთ მოქმედი ფილიალი.'; end if;
  if branch.supervisor_user_id is null then raise exception 'ფილიალს აქტიური ვაიზერი არ ჰყავს.'; end if;
  select * into supervisor from public.profiles where id=branch.supervisor_user_id and active and deleted_at is null and role='inspector';
  if supervisor.id is null then raise exception 'ფილიალს აქტიური ვაიზერი არ ჰყავს.'; end if;
  if actor.role='monitoring' and (entry_value at time zone 'Asia/Tbilisi')::date<>(now() at time zone 'Asia/Tbilisi')::date then raise exception 'მონიტორინგს მხოლოდ მიმდინარე დღის ჩანაწერის დამატება შეუძლია.'; end if;
  insert into public.supervisor_branch_time(branch_id,supervisor_user_id,supervisor_name,entry_at,exit_at,recorded_by)
  values(branch.id,supervisor.id,supervisor.name,entry_value,exit_value,actor.id) returning * into item;
  return jsonb_build_object('id',item.id,'ok',true);
 end if;

 match:=regexp_match(route,'^/supervisor-time/([0-9]+)$');
 if match is not null and method='PATCH' then
  select * into item from public.supervisor_branch_time where id=match[1]::bigint;
  if item.id is null then raise exception 'ჩანაწერი ვერ მოიძებნა.'; end if;
  if actor.role='monitoring' and (item.entry_at at time zone 'Asia/Tbilisi')::date<>(now() at time zone 'Asia/Tbilisi')::date then raise exception 'მონიტორინგს მხოლოდ მიმდინარე დღის ჩანაწერის რედაქტირება შეუძლია.' using errcode='42501'; end if;
  entry_value:=case when payload ? 'entry_at' then nullif(payload->>'entry_at','')::timestamptz else item.entry_at end;
  exit_value:=case when payload ? 'exit_at' then nullif(payload->>'exit_at','')::timestamptz else item.exit_at end;
  if exit_value is not null and exit_value<entry_value then raise exception 'გასვლის დრო შესვლის დროზე ადრე ვერ იქნება.'; end if;
  if actor.role='monitoring' and (entry_value at time zone 'Asia/Tbilisi')::date<>(now() at time zone 'Asia/Tbilisi')::date then raise exception 'მონიტორინგს მხოლოდ მიმდინარე დღის ჩანაწერის შენახვა შეუძლია.'; end if;
  update public.supervisor_branch_time set entry_at=entry_value,exit_at=exit_value,updated_at=now() where id=item.id;
  return jsonb_build_object('id',item.id,'ok',true);
 end if;
 raise exception 'უცნობი supervisor time route.' using errcode='22023';
end $$;
revoke all on function public.supervisor_time_api(text,text,jsonb) from public,anon;
grant execute on function public.supervisor_time_api(text,text,jsonb) to authenticated;

create or replace function public.monitoring_report_api(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to public, app_private as $$
declare actor public.profiles%rowtype; from_date date; to_date date; criterion_id bigint; branch_id integer; sort_value text:=coalesce(nullif(payload->>'sort',''),'penalty-desc'); result jsonb;
begin
 select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null;
 if actor.id is null or actor.role<>'admin' then raise exception 'რეპორტი მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
 from_date:=nullif(payload->>'from','')::date; to_date:=nullif(payload->>'to','')::date; branch_id:=nullif(payload->>'branch','')::integer; criterion_id:=nullif(payload->>'criterion','')::bigint;
 if from_date is not null and to_date is not null and from_date>to_date then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.'; end if;
 if sort_value not in ('penalty-desc','penalty-asc','count-desc','count-asc') then raise exception 'არასწორი დალაგება.'; end if;
 with grouped as (
  select i.branch_id,b.name branch_name,count(*)::integer issue_count,round(sum(i.penalty_applied),2) penalty_sum,
   count(*) filter(where i.status='open')::integer open_count,count(*) filter(where i.status='closed')::integer closed_count
  from public.monitoring_issues i join public.branches b on b.id=i.branch_id
  where i.deleted_at is null and (from_date is null or i.created_at >= (from_date::timestamp at time zone 'Asia/Tbilisi')) and (to_date is null or i.created_at < ((to_date+1)::timestamp at time zone 'Asia/Tbilisi')) and (branch_id is null or i.branch_id=branch_id) and (criterion_id is null or i.criterion_id=criterion_id)
  group by i.branch_id,b.name
 )
 select jsonb_build_object('sort',sort_value,'criteria',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.monitoring_criteria c),'[]'::jsonb),'rows',coalesce((select jsonb_agg(to_jsonb(g) order by case when sort_value='penalty-desc' then penalty_sum end desc,case when sort_value='penalty-asc' then penalty_sum end asc,case when sort_value='count-desc' then issue_count end desc,case when sort_value='count-asc' then issue_count end asc,branch_name) from grouped),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function public.monitoring_report_api(jsonb) from public,anon;
grant execute on function public.monitoring_report_api(jsonb) to authenticated;

create or replace function app_private.report_data_paged(p_from date,p_to date,p_branch integer,p_page integer default 0,p_page_size integer default 5)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare result jsonb; page_no integer:=greatest(coalesce(p_page,0),0); size_no integer:=least(greatest(coalesce(p_page_size,5),1),100);
begin
 if p_from>p_to then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.'; end if;
 with filtered as (select i.* from public.inspections i where i.deleted_at is null and (p_from is null or i.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi')) and (p_to is null or i.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi')) and (p_branch is null or i.branch_id=p_branch)),
 scores as (select i.id,i.branch_id,i.branch_name,i.user_id,i.user_name,i.created_at,i.note,i.request_key,i.started_at,i.duration_seconds,i.revision,round(avg(a.rating),2) score,count(a.id) answer_count from filtered i join public.answers a on a.inspection_id=i.id group by i.id,i.branch_id,i.branch_name,i.user_id,i.user_name,i.created_at,i.note,i.request_key,i.started_at,i.duration_seconds,i.revision),
 latest as (select * from scores order by created_at desc,id desc limit size_no offset page_no*size_no),
 monitoring as (select mi.branch_id,round(sum(mi.penalty_applied),2) monitoring_penalty,jsonb_agg(jsonb_build_object('title',mc.title,'penalty',mi.penalty_applied,'created_at',mi.created_at) order by mi.created_at desc) monitoring_issues from public.monitoring_issues mi join public.monitoring_criteria mc on mc.id=mi.criterion_id where mi.deleted_at is null and (p_from is null or mi.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi')) and (p_to is null or mi.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi')) and (p_branch is null or mi.branch_id=p_branch) group by mi.branch_id),
 bybranch as (select i.branch_id,i.branch_name,round(avg(a.rating),2) base_score,coalesce(m.monitoring_penalty,0)::numeric monitoring_penalty,coalesce(m.monitoring_issues,'[]'::jsonb) monitoring_issues,round(greatest(avg(a.rating)-coalesce(m.monitoring_penalty,0),0),2) score,count(distinct i.id) inspections from filtered i join public.answers a on a.inspection_id=i.id left join monitoring m on m.branch_id=i.branch_id group by i.branch_id,i.branch_name,m.monitoring_penalty,m.monitoring_issues),
 stats as (select count(a.id) answers,round(avg(a.rating),2) base_score,round(coalesce((select avg(monitoring_penalty) from monitoring),0),2) monitoring_penalty,round(greatest(avg(a.rating)-coalesce((select avg(monitoring_penalty) from monitoring),0),0),2) score,count(*) filter(where a.rating<=2) issues from filtered i join public.answers a on a.inspection_id=i.id)
 select jsonb_build_object('total',(select count(*) from filtered),'page',page_no,'page_size',size_no,'rows',coalesce((select jsonb_agg(to_jsonb(latest) order by created_at desc,id desc) from latest),'[]'::jsonb),'stats',(select to_jsonb(stats) from stats),'byBranch',coalesce((select jsonb_agg(to_jsonb(bybranch) order by score desc,branch_name) from bybranch),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.report_data_paged(date,date,integer,integer,integer) from public,anon,authenticated;

do $outer$ declare definition text; old text:= $route$if route in ('/reports','/export') and method='GET' then return app_private.report_data(nullif(payload->>'from','')::date,nullif(payload->>'to','')::date,nullif(payload->>'branch','')::integer,route='/export');end if;$route$; new text:= $route$if route='/reports' and method='GET' then return app_private.report_data_paged(nullif(payload->>'from','')::date,nullif(payload->>'to','')::date,nullif(payload->>'branch','')::integer,(payload->>'page')::integer,(payload->>'page_size')::integer);end if; if route='/export' and method='GET' then return app_private.report_data(nullif(payload->>'from','')::date,nullif(payload->>'to','')::date,nullif(payload->>'branch','')::integer,true);end if;$route$; begin select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition; if position(old in definition)=0 then raise exception 'app_api report route was not found'; end if; execute replace(definition,old,new); end $outer$;
drop function if exists public.period_comparison_api(jsonb);

