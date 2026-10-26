-- Add Monitoring penalties and reasons to the unified Overview calculations.

create or replace function app_private.branch_comparison(payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; criteria integer[]; balanced boolean=coalesce((payload->>'balanced')::boolean,false);
begin
 if nullif(payload->>'from','')::date > nullif(payload->>'to','')::date then raise exception 'შეამოწმეთ თარიღების პერიოდი.'; end if;
 if nullif(payload->>'criteria','') is not null then
  if length(payload->>'criteria')>2000 or payload->>'criteria' !~ '^[0-9]+(,[0-9]+)*$' then raise exception 'შეამოწმეთ კრიტერიუმების არჩევანი.'; end if;
  criteria=string_to_array(payload->>'criteria',',')::integer[];
 end if;
 with ranked as (
  select i.*,row_number() over(partition by i.branch_id order by i.created_at desc,i.id desc) position
  from public.inspections i
  where (nullif(payload->>'from','') is null or i.created_at >= (nullif(payload->>'from','')::date::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'to','') is null or i.created_at < ((nullif(payload->>'to','')::date+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'branch','') is null or i.branch_id=(payload->>'branch')::integer)
 ), counts as (select branch_id,count(*) n from ranked group by branch_id), common as (select coalesce(min(n),0) n,count(*) branches from counts),
 picked as (select r.* from ranked r where not balanced or r.position<=(select n from common)),
 grouped as (
  select p.branch_id,coalesce(b.name,max(p.branch_name)) branch_name,
   round(avg(a.rating),2) base_score,count(distinct p.id) inspections,
   count(distinct p.id) filter(where a.id is not null) rated_inspections,
   count(a.id) answers,count(a.id) filter(where a.rating<=2) issues
  from picked p left join public.branches b on b.id=p.branch_id
  left join public.answers a on a.inspection_id=p.id and (criteria is null or a.question_id=any(criteria))
  group by p.branch_id,b.name
 ), monitoring as (
  select mi.branch_id,round(sum(mi.penalty_applied),2) monitoring_penalty,
   jsonb_agg(jsonb_build_object('title',mc.title,'penalty',mi.penalty_applied,'created_at',mi.created_at) order by mi.created_at desc) monitoring_issues
  from public.monitoring_issues mi join public.monitoring_criteria mc on mc.id=mi.criterion_id
  where mi.deleted_at is null
   and (nullif(payload->>'from','') is null or mi.created_at >= (nullif(payload->>'from','')::date::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'to','') is null or mi.created_at < ((nullif(payload->>'to','')::date+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'branch','') is null or mi.branch_id=(payload->>'branch')::integer)
  group by mi.branch_id
 ), final_rows as (
  select g.branch_id,g.branch_name,g.base_score,g.inspections,g.rated_inspections,g.answers,g.issues,
   coalesce(m.monitoring_penalty,0)::numeric monitoring_penalty,
   coalesce(m.monitoring_issues,'[]'::jsonb) monitoring_issues,
   round(greatest(coalesce(g.base_score,0)-coalesce(m.monitoring_penalty,0),0),2) score
  from grouped g left join monitoring m on m.branch_id=g.branch_id
 )
 select jsonb_build_object('common_count',(select n from common),'branch_count',(select branches from common),'total_selected',(select count(*) from picked),
  'rows',coalesce((select jsonb_agg(to_jsonb(final_rows) order by score desc nulls last,branch_name) from final_rows),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.branch_comparison(jsonb) from public,anon,authenticated;

create or replace function app_private.report_data(p_from date,p_to date,p_branch integer,p_export boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_from>p_to then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.'; end if;
 if p_export then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into result from (
   select i.id,i.created_at,i.branch_name,i.user_name,a.question_text,a.rating,i.note,
    coalesce((select round(sum(mi.penalty_applied),2) from public.monitoring_issues mi where mi.branch_id=i.branch_id and mi.deleted_at is null and (p_from is null or mi.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi')) and (p_to is null or mi.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))),0) monitoring_penalty
   from public.inspections i join public.answers a on a.inspection_id=i.id
   where (p_from is null or i.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi'))
    and (p_to is null or i.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))
    and (p_branch is null or i.branch_id=p_branch)
   order by i.created_at desc,a.id limit 50001
  ) x;
  if jsonb_array_length(result)>50000 then raise exception 'ექსპორტისთვის შეამცირეთ პერიოდი (მაქსიმუმ 50 000 პასუხი).'; end if;
  return result;
 end if;
 with filtered as (
  select i.* from public.inspections i
  where (p_from is null or i.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi'))
   and (p_to is null or i.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (p_branch is null or i.branch_id=p_branch)
 ), scores as (
  select i.*,round(avg(a.rating),2) score,count(a.id) answer_count from filtered i join public.answers a on a.inspection_id=i.id group by i.id,i.branch_id,i.branch_name,i.user_id,i.user_name,i.created_at,i.note,i.request_key,i.started_at,i.duration_seconds,i.revision
 ), latest as (select * from scores order by created_at desc,id desc limit 200),
 monitoring as (
  select mi.branch_id,round(sum(mi.penalty_applied),2) monitoring_penalty,
   jsonb_agg(jsonb_build_object('title',mc.title,'penalty',mi.penalty_applied,'created_at',mi.created_at) order by mi.created_at desc) monitoring_issues
  from public.monitoring_issues mi join public.monitoring_criteria mc on mc.id=mi.criterion_id
  where mi.deleted_at is null
   and (p_from is null or mi.created_at >= (p_from::timestamp at time zone 'Asia/Tbilisi'))
   and (p_to is null or mi.created_at < ((p_to+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (p_branch is null or mi.branch_id=p_branch)
  group by mi.branch_id
 ),
 bybranch as (
  select i.branch_id,i.branch_name,round(avg(a.rating),2) base_score,
   coalesce(m.monitoring_penalty,0)::numeric monitoring_penalty,
   coalesce(m.monitoring_issues,'[]'::jsonb) monitoring_issues,
   round(greatest(avg(a.rating)-coalesce(m.monitoring_penalty,0),0),2) score,
   count(distinct i.id) inspections
  from filtered i join public.answers a on a.inspection_id=i.id
   left join monitoring m on m.branch_id=i.branch_id
  group by i.branch_id,i.branch_name,m.monitoring_penalty,m.monitoring_issues
 ), stats as (
  select count(a.id) answers,round(avg(a.rating),2) base_score,
   round(coalesce((select avg(monitoring_penalty) from monitoring),0),2) monitoring_penalty,
   round(greatest(avg(a.rating)-coalesce((select avg(monitoring_penalty) from monitoring),0),0),2) score,
   count(*) filter(where a.rating<=2) issues
  from filtered i join public.answers a on a.inspection_id=i.id
 )
 select jsonb_build_object('total',(select count(*) from filtered),
  'rows',coalesce((select jsonb_agg(to_jsonb(latest) order by created_at desc,id desc) from latest),'[]'::jsonb),
  'stats',(select to_jsonb(stats) from stats),
  'byBranch',coalesce((select jsonb_agg(to_jsonb(bybranch) order by score desc,branch_name) from bybranch),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.report_data(date,date,integer,boolean) from public,anon,authenticated;


