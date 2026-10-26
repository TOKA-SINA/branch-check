-- Weekly plan progress summary and per-branch distinct visit counts.
create or replace function public.compliance_api(route text, method text default 'GET', payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,app_private as $$
declare actor public.profiles%rowtype; leave_row public.supervisor_leave_requests%rowtype; match text[]; week date; start_date date; end_date date;
begin
 select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null;
 if actor.id is null then raise exception 'გთხოვთ შეხვიდეთ სისტემაში.' using errcode='42501'; end if;
 if route='/weekly' and method='GET' then
  if actor.role='monitoring' then raise exception 'წვდომა არ გაქვთ.' using errcode='42501'; end if;
  week:=coalesce(nullif(payload->>'week_start','')::date,date_trunc('week',(now() at time zone 'Asia/Tbilisi'))::date);
  return jsonb_build_object('week_start',week,
   'summary',coalesce((select jsonb_build_object(
      'total_branches',count(*),
      'completed_branches',count(*) filter(where x.exempt or x.inspection_days>=2),
      'remaining_branches',count(*) filter(where not x.exempt and x.inspection_days<2),
      'remaining_visits',coalesce(sum(case when x.exempt then 0 else greatest(2-x.inspection_days,0) end),0)
    ) from (
      select b.id,
       count(distinct ((i.created_at at time zone 'Asia/Tbilisi')::date)) filter(where i.user_id=b.supervisor_user_id and ((i.created_at at time zone 'Asia/Tbilisi')::date)>=week and ((i.created_at at time zone 'Asia/Tbilisi')::date)<week+7) inspection_days,
       (exists(select 1 from public.supervisor_leave_requests l where l.supervisor_id=b.supervisor_user_id and l.status='approved' and l.start_date<=week+6 and l.end_date>=week)
        or exists(select 1 from public.branch_assignment_history h where h.branch_id=b.id and h.created_at at time zone 'Asia/Tbilisi' >= week and h.created_at at time zone 'Asia/Tbilisi' < week+7)) exempt
      from public.branches b left join public.inspections i on i.branch_id=b.id and i.deleted_at is null
      where b.active and (actor.role='admin' or b.supervisor_user_id=actor.id)
      group by b.id,b.supervisor_user_id
    ) x),jsonb_build_object('total_branches',0,'completed_branches',0,'remaining_branches',0,'remaining_visits',0)),
   'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.branch_name) from (
    select b.id branch_id,b.name branch_name,b.supervisor_user_id,p.name supervisor_name,
     count(distinct ((i.created_at at time zone 'Asia/Tbilisi')::date)) filter(where i.user_id=b.supervisor_user_id and ((i.created_at at time zone 'Asia/Tbilisi')::date)>=week and ((i.created_at at time zone 'Asia/Tbilisi')::date)<week+7) inspection_days,
     greatest(2-count(distinct ((i.created_at at time zone 'Asia/Tbilisi')::date)) filter(where i.user_id=b.supervisor_user_id and ((i.created_at at time zone 'Asia/Tbilisi')::date)>=week and ((i.created_at at time zone 'Asia/Tbilisi')::date)<week+7),0) remaining_visits,
     max(i.created_at) filter(where i.user_id=b.supervisor_user_id and ((i.created_at at time zone 'Asia/Tbilisi')::date)>=week and ((i.created_at at time zone 'Asia/Tbilisi')::date)<week+7) last_inspection_at,
     exists(select 1 from public.supervisor_leave_requests l where l.supervisor_id=b.supervisor_user_id and l.status='approved' and l.start_date<=week+6 and l.end_date>=week) vacation_exempt,
     exists(select 1 from public.branch_assignment_history h where h.branch_id=b.id and h.created_at at time zone 'Asia/Tbilisi' >= week and h.created_at at time zone 'Asia/Tbilisi' < week+7) assignment_exempt
    from public.branches b left join public.profiles p on p.id=b.supervisor_user_id left join public.inspections i on i.branch_id=b.id and i.deleted_at is null
    where b.active and (actor.role='admin' or b.supervisor_user_id=actor.id)
    group by b.id,b.name,b.supervisor_user_id,p.name
   ) x),'[]'::jsonb));
 end if;
 if route='/leave' and method='GET' then
  if actor.role='monitoring' then raise exception 'წვდომა არ გაქვთ.' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from public.supervisor_leave_requests l where actor.role='admin' or l.supervisor_id=actor.id),'[]'::jsonb);
 end if;
 if route='/leave' and method='POST' then
  if actor.role<>'inspector' then raise exception 'შვებულების მოთხოვნა მხოლოდ ვაიზერს შეუძლია.' using errcode='42501'; end if;
  start_date:=nullif(payload->>'start_date','')::date; end_date:=nullif(payload->>'end_date','')::date;
  if start_date is null or end_date is null or end_date<start_date then raise exception 'მიუთითეთ სწორი თარიღები.'; end if;
  insert into public.supervisor_leave_requests(supervisor_id,start_date,end_date,reason) values(actor.id,start_date,end_date,nullif(btrim(payload->>'reason'),'') ) returning * into leave_row;
  insert into public.audit(user_id,action,target) values(actor.id,'vacation.requested',leave_row.id::text);
  perform app_private.notify_admins('vacation.requested','leave_request',leave_row.id::text,'შვებულების მოთხოვნა','ვაიზერმა შვებულება მოითხოვა.'); return to_jsonb(leave_row);
 end if;
 match:=regexp_match(route,'^/leave/([0-9]+)/review$');
 if match is not null and method='PATCH' then
  if actor.role<>'admin' or payload->>'status' not in ('approved','rejected') then raise exception 'წვდომა მხოლოდ Admin-ს აქვს.' using errcode='42501'; end if;
  update public.supervisor_leave_requests set status=payload->>'status',reviewed_by=actor.id,reviewed_at=now() where id=match[1]::bigint and status='pending' returning * into leave_row;
  if leave_row.id is null then raise exception 'მოთხოვნა ვერ მოიძებნა ან უკვე განხილულია.'; end if;
  insert into public.audit(user_id,action,target) values(actor.id,case when leave_row.status='approved' then 'vacation.approved' else 'vacation.rejected' end,leave_row.id::text);
  perform app_private.notify_user(leave_row.supervisor_id,'vacation.reviewed','leave_request',leave_row.id::text,'შვებულების მოთხოვნის პასუხი','Admin-მა თქვენი მოთხოვნა განიხილა.'); return to_jsonb(leave_row);
 end if;
 match:=regexp_match(route,'^/leave/([0-9]+)/cancel$');
 if match is not null and method='PATCH' then
  update public.supervisor_leave_requests set status='cancelled',cancelled_at=now() where id=match[1]::bigint and supervisor_id=actor.id and status='approved' returning * into leave_row;
  if leave_row.id is null then raise exception 'გაუქმება შეუძლებელია.'; end if;
  insert into public.audit(user_id,action,target) values(actor.id,'vacation.cancelled',leave_row.id::text); return to_jsonb(leave_row);
 end if;
 raise exception 'უცნობი compliance route.' using errcode='22023';
end $$;
revoke all on function public.compliance_api(text,text,jsonb) from public,anon;
grant execute on function public.compliance_api(text,text,jsonb) to authenticated;

