-- Admin issue close action and two-date snapshot comparison.
do $migration$
declare definition text; old text; new text;
begin
 select pg_get_functiondef('public.monitoring_api(text,text,jsonb)'::regprocedure) into definition;
 old:=$old$ match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/resolve$');$old$;
 if position(old in definition)=0 then raise exception 'monitoring_api resolve route was not found'; end if;
 new:=$new$ match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/close$');
 if match is not null and method='PATCH' then
  issue_id:=match[1]::bigint;
  if actor.role<>'admin' then raise exception 'საკითხის დახურვა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
  select * into issue from public.monitoring_issues where id=issue_id and deleted_at is null;
  if issue.id is null then raise exception 'საკითხი ვერ მოიძებნა.'; end if;
  if issue.status<>'open' then raise exception 'საკითხი უკვე დახურულია.'; end if;
  update public.monitoring_issues set status='closed',closed_at=now(),closed_by=actor.id,updated_at=now() where id=issue_id;
  insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue_id,actor.id,'issue.closed',jsonb_build_object('status','closed','by','admin'));
  return jsonb_build_object('ok',true,'id',issue_id,'status','closed');
 end if;

 match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/resolve$');$new$;
 definition:=replace(definition,old,new);
 execute definition;
end $migration$;

create or replace function public.period_comparison_api(payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,app_private as $$
declare
 actor public.profiles%rowtype;
 start_date date:=nullif(payload->>'start','')::date;
 end_date date:=nullif(payload->>'end','')::date;
 branch_filter integer[];
 result jsonb;
begin
 select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null and role='admin';
 if actor.id is null then raise exception 'წვდომა მხოლოდ Admin-ს აქვს.' using errcode='42501'; end if;
 if start_date is null or end_date is null or end_date<start_date then raise exception 'აირჩიეთ სწორი საწყისი და საბოლოო თარიღები.'; end if;
 if nullif(payload->>'branches','') is not null then branch_filter:=string_to_array(payload->>'branches',',')::integer[]; end if;
 with snapshots as (
   select start_date as snapshot_date
   union all
   select end_date
 ), selected_branches as (
   select b.id from public.branches b where b.active and (branch_filter is null or b.id=any(branch_filter))
 ), base as (
   select s.snapshot_date,
    round(avg(a.rating),2) base_score,
    count(distinct i.id) inspection_count
   from snapshots s cross join selected_branches b
   left join public.inspections i on i.branch_id=b.id and i.deleted_at is null and ((i.created_at at time zone 'Asia/Tbilisi')::date)<=s.snapshot_date
   left join public.answers a on a.inspection_id=i.id
   group by s.snapshot_date
 ), issues as (
   select s.snapshot_date,
    count(mi.id)::integer monitoring_issues,
    coalesce(sum(mi.penalty_applied),0)::numeric monitoring_penalty
   from snapshots s cross join selected_branches b
   left join public.monitoring_issues mi on mi.branch_id=b.id and mi.deleted_at is null and ((mi.created_at at time zone 'Asia/Tbilisi')::date)<=s.snapshot_date
   group by s.snapshot_date
 ), all_data as (
   select b.snapshot_date,b.base_score,b.inspection_count,i.monitoring_issues,i.monitoring_penalty,
    case when b.base_score is null then null else greatest(b.base_score-i.monitoring_penalty,0) end final_score
   from base b join issues i using(snapshot_date)
 )
 select jsonb_build_object(
  'start',(select jsonb_build_object('date',snapshot_date,'base_score',base_score,'inspection_count',inspection_count,'monitoring_penalty',monitoring_penalty,'monitoring_issues',monitoring_issues,'final_score',final_score) from all_data where snapshot_date=start_date),
  'end',(select jsonb_build_object('date',snapshot_date,'base_score',base_score,'inspection_count',inspection_count,'monitoring_penalty',monitoring_penalty,'monitoring_issues',monitoring_issues,'final_score',final_score) from all_data where snapshot_date=end_date),
  'delta',jsonb_build_object(
   'score_points',(select e.final_score-s.final_score from all_data s join all_data e on e.snapshot_date=end_date where s.snapshot_date=start_date),
   'score_percent',(select case when s.final_score is null or s.final_score=0 then null else ((e.final_score-s.final_score)/s.final_score*100) end from all_data s join all_data e on e.snapshot_date=end_date where s.snapshot_date=start_date),
   'issue_points',(select e.monitoring_issues-s.monitoring_issues from all_data s join all_data e on e.snapshot_date=end_date where s.snapshot_date=start_date),
   'issue_percent',(select case when s.monitoring_issues=0 then null else ((e.monitoring_issues-s.monitoring_issues)::numeric/s.monitoring_issues*100) end from all_data s join all_data e on e.snapshot_date=end_date where s.snapshot_date=start_date)
  ),
  'branch_count',(select count(*) from selected_branches)
 ) into result;
 return result;
end
$$;
revoke all on function public.period_comparison_api(jsonb) from public,anon;
grant execute on function public.period_comparison_api(jsonb) to authenticated;

