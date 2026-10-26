create or replace function public.monitoring_admin_api(route text, method text default 'GET', payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,app_private as $$
declare actor public.profiles%rowtype; criterion public.monitoring_criteria%rowtype; branch public.branches%rowtype; supervisor uuid; match text[];
begin
 select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null and role='admin';
 if actor.id is null then raise exception 'წვდომა მხოლოდ Admin-ს აქვს.' using errcode='42501'; end if;
 if route='/criteria' and method='GET' then
  return coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.monitoring_criteria c),'[]'::jsonb);
 end if;
 if route='/criteria' and method='POST' then
  if nullif(btrim(payload->>'title'),'') is null or payload->>'severity' not in ('light','important','critical') then raise exception 'შეავსეთ criterion-ის ველები.'; end if;
  insert into public.monitoring_criteria(title,severity,penalty_amount) values(btrim(payload->>'title'),payload->>'severity',abs((payload->>'penalty_amount')::numeric)) returning * into criterion;
  insert into public.audit(user_id,action,target) values(actor.id,'monitoring_criterion.created',criterion.id::text);
  return to_jsonb(criterion);
 end if;
 match:=regexp_match(route,'^/criteria/([0-9]+)$');
 if match is not null and method='PATCH' then
  update public.monitoring_criteria set title=case when payload?'title' then btrim(payload->>'title') else title end,
   severity=case when payload?'severity' then payload->>'severity' else severity end,
   penalty_amount=case when payload?'penalty_amount' then abs((payload->>'penalty_amount')::numeric) else penalty_amount end,
   active=case when payload?'active' then (payload->>'active')::boolean else active end
   where id=match[1]::bigint returning * into criterion;
  if criterion.id is null then raise exception 'criterion ვერ მოიძებნა.'; end if;
  insert into public.audit(user_id,action,target) values(actor.id,case when criterion.active then 'monitoring_criterion.updated' else 'monitoring_criterion.archived' end,criterion.id::text);
  return to_jsonb(criterion);
 end if;
 if route='/branches' and method='GET' then
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.name) from (select b.id,b.name,b.active,b.supervisor_user_id,p.name supervisor_name from public.branches b left join public.profiles p on p.id=b.supervisor_user_id) x),'[]'::jsonb);
 end if;
 match:=regexp_match(route,'^/branches/([0-9]+)/assignment$');
 if match is not null and method='PATCH' then
  select * into branch from public.branches where id=match[1]::integer;
  if branch.id is null then raise exception 'ფილიალი ვერ მოიძებნა.'; end if;
  supervisor:=nullif(payload->>'supervisor_user_id','')::uuid;
  if branch.active and (supervisor is null or not exists(select 1 from public.profiles p where p.id=supervisor and p.active and p.deleted_at is null and p.role='inspector')) then raise exception 'აირჩიეთ მოქმედი ვაიზერი.'; end if;
  update public.branches set supervisor_user_id=supervisor where id=branch.id;
  insert into public.branch_assignment_history(branch_id,previous_supervisor_id,supervisor_id,changed_by,reason) values(branch.id,branch.supervisor_user_id,supervisor,actor.id,case when branch.supervisor_user_id is null then 'assignment' else 'reassignment' end);
  insert into public.audit(user_id,action,target) values(actor.id,case when branch.supervisor_user_id is null then 'branch.assigned' else 'branch.reassigned' end,branch.id::text);
  return jsonb_build_object('ok',true,'branch_id',branch.id,'supervisor_user_id',supervisor);
 end if;
 raise exception 'უცნობი admin monitoring route.' using errcode='22023';
end $$;
revoke all on function public.monitoring_admin_api(text,text,jsonb) from public,anon;
grant execute on function public.monitoring_admin_api(text,text,jsonb) to authenticated;

