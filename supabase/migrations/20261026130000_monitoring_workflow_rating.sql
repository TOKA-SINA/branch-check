-- Monitoring workflow and rating recalculation.
-- Monitoring records are active immediately; only Admin may edit or hard-delete them.

alter table public.monitoring_issues drop constraint if exists monitoring_issues_status_check;

update public.monitoring_issues
set status='active', closed_at=null, closed_by=null
where status is distinct from 'active';
alter table public.monitoring_issues add constraint monitoring_issues_status_check check (status='active');

create or replace function app_private.refresh_monitoring_penalty()
returns trigger language plpgsql security definer set search_path=public,app_private as $$
begin
  if new.penalty_amount is distinct from old.penalty_amount then
    update public.monitoring_issues set penalty_applied=new.penalty_amount, updated_at=now()
    where criterion_id=new.id and deleted_at is null;
  end if;
  return new;
end
$$;

create or replace function public.monitoring_api(route text, method text default 'GET', payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,app_private as $$
declare
  actor public.profiles%rowtype; issue public.monitoring_issues%rowtype; issue_id bigint;
  branch public.branches%rowtype; criterion public.monitoring_criteria%rowtype;
  new_branch_id integer; new_criterion_id bigint; new_penalty numeric(12,2);
  match text[]; page_no integer:=greatest(coalesce((payload->>'page')::integer,0),0);
  page_size integer:=least(greatest(coalesce((payload->>'page_size')::integer,50),1),100);
  from_date timestamptz; to_date timestamptz;
begin
  select * into actor from public.profiles where id=auth.uid() and active and deleted_at is null;
  if actor.id is null then raise exception 'გთხოვთ შეხვიდეთ სისტემაში.' using errcode='42501'; end if;

  if route='/monitoring/catalog' and method='GET' then
    return jsonb_build_object(
      'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.active),'[]'::jsonb),
      'criteria',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.monitoring_criteria c where c.active),'[]'::jsonb)
    );
  end if;

  if route='/monitoring/issues' and method='GET' then
    from_date:=nullif(payload->>'from','')::timestamptz; to_date:=nullif(payload->>'to','')::timestamptz;
    return jsonb_build_object(
      'page',page_no,'page_size',page_size,
      'total',(select count(*) from public.monitoring_issues i join public.branches b on b.id=i.branch_id
        where i.deleted_at is null and (actor.role='admin' or (actor.role='monitoring' and i.created_by=actor.id) or (actor.role='inspector' and b.supervisor_user_id=actor.id))
          and (from_date is null or i.created_at>=from_date) and (to_date is null or i.created_at<to_date)),
      'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select i.id,i.branch_id,b.name branch_name,i.criterion_id,c.title criterion_title,c.severity,i.created_by,p.name creator_name,
          'active'::text status,i.comment,i.penalty_applied,i.created_at,i.updated_at
        from public.monitoring_issues i join public.branches b on b.id=i.branch_id join public.monitoring_criteria c on c.id=i.criterion_id
          left join public.profiles p on p.id=i.created_by
        where i.deleted_at is null and (actor.role='admin' or (actor.role='monitoring' and i.created_by=actor.id) or (actor.role='inspector' and b.supervisor_user_id=actor.id))
          and (from_date is null or i.created_at>=from_date) and (to_date is null or i.created_at<to_date)
        order by i.created_at desc limit page_size offset page_no*page_size
      ) x),'[]'::jsonb)
    );
  end if;

  match:=regexp_match(route,'^/monitoring/issues/([0-9]+)$');
  if match is not null and method='GET' then
    issue_id:=match[1]::bigint;
    select * into issue from public.monitoring_issues where id=issue_id and deleted_at is null;
    if issue.id is null or not app_private.can_monitoring_issue(issue.branch_id,issue.created_by) then raise exception 'საკითხზე წვდომა არ გაქვთ.' using errcode='42501'; end if;
    return (select jsonb_build_object(
      'id',i.id,'branch_id',i.branch_id,'branch_name',b.name,'criterion_id',i.criterion_id,'criterion_title',c.title,
      'severity',c.severity,'created_by',i.created_by,'creator_name',p.name,'status','active'::text,'comment',i.comment,
      'penalty_applied',i.penalty_applied,'created_at',i.created_at,'updated_at',i.updated_at,
      'actions',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.issue_actions a where a.issue_id=i.id),'[]'::jsonb),
      'attachments',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.issue_id=i.id and a.deleted_at is null),'[]'::jsonb)
    ) from public.monitoring_issues i join public.branches b on b.id=i.branch_id join public.monitoring_criteria c on c.id=i.criterion_id
      left join public.profiles p on p.id=i.created_by where i.id=issue_id);
  end if;

  if route='/monitoring/issues' and method='POST' then
    if actor.role not in ('admin','monitoring') then raise exception 'საკითხის დაფიქსირება მხოლოდ მონიტორინგს შეუძლია.' using errcode='42501'; end if;
    select * into branch from public.branches where id=(payload->>'branch_id')::integer and active;
    if branch.id is null then raise exception 'აირჩიეთ მოქმედი ფილიალი.'; end if;
    select * into criterion from public.monitoring_criteria where id=(payload->>'criterion_id')::bigint and active;
    if criterion.id is null then raise exception 'აირჩიეთ მოქმედი Monitoring criterion.'; end if;
    insert into public.monitoring_issues(branch_id,criterion_id,created_by,comment,penalty_applied,status)
    values(branch.id,criterion.id,actor.id,nullif(btrim(payload->>'comment'),''),criterion.penalty_amount,'active') returning id into issue_id;
    insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue_id,actor.id,'issue.created',jsonb_build_object('criterion_id',criterion.id,'branch_id',branch.id));
    if branch.supervisor_user_id is not null then perform app_private.notify_user(branch.supervisor_user_id,'issue.created','monitoring_issue',issue_id::text,'ახალი მონიტორინგის საკითხი','თქვენს ფილიალში ახალი საკითხი დაფიქსირდა.'); end if;
    perform app_private.notify_admins('issue.created','monitoring_issue',issue_id::text,'ახალი მონიტორინგის საკითხი','ახალი მონიტორინგის საკითხი დაფიქსირდა.');
    return jsonb_build_object('id',issue_id,'status','active');
  end if;

  if match is not null and method='PATCH' then
    if actor.role<>'admin' then raise exception 'საკითხის შეცვლა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
    select * into issue from public.monitoring_issues where id=match[1]::bigint and deleted_at is null;
    if issue.id is null then raise exception 'საკითხი ვერ მოიძებნა.'; end if;
    new_branch_id:=issue.branch_id; new_criterion_id:=issue.criterion_id; new_penalty:=issue.penalty_applied;
    if payload ? 'branch_id' then new_branch_id:=(payload->>'branch_id')::integer; end if;
    if payload ? 'criterion_id' then new_criterion_id:=(payload->>'criterion_id')::bigint; end if;
    if payload ? 'penalty_amount' then new_penalty:=abs((payload->>'penalty_amount')::numeric); end if;
    select * into branch from public.branches where id=new_branch_id and active;
    if branch.id is null then raise exception 'აირჩიეთ მოქმედი ფილიალი.'; end if;
    select * into criterion from public.monitoring_criteria where id=new_criterion_id;
    if criterion.id is null then raise exception 'კრიტერიუმი ვერ მოიძებნა.'; end if;
    if not (payload ? 'penalty_amount') and payload ? 'criterion_id' then new_penalty:=criterion.penalty_amount; end if;
    update public.monitoring_issues set branch_id=new_branch_id,criterion_id=new_criterion_id,
      comment=case when payload ? 'comment' then nullif(btrim(payload->>'comment'),'') else comment end,
      penalty_applied=new_penalty,updated_at=now() where id=issue.id;
    insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue.id,actor.id,'issue.updated',payload);
    return jsonb_build_object('ok',true,'id',issue.id,'penalty_applied',new_penalty);
  end if;

  if match is not null and method='DELETE' then
    if actor.role<>'admin' then raise exception 'საკითხის წაშლა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
    select * into issue from public.monitoring_issues where id=match[1]::bigint and deleted_at is null;
    if issue.id is null then raise exception 'საკითხი ვერ მოიძებნა.'; end if;
    delete from public.issue_actions where issue_id=issue.id;
    delete from public.attachments where issue_id=issue.id;
    delete from public.issue_change_requests where issue_id=issue.id;
    delete from public.monitoring_issues where id=issue.id;
    return jsonb_build_object('ok',true,'id',issue.id,'deleted',true);
  end if;

  if route='/notifications' and method='GET' then return coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from public.notifications n where n.recipient_id=actor.id),'[]'::jsonb); end if;
  match:=regexp_match(route,'^/notifications/([0-9]+)$');
  if match is not null and method='PATCH' then
    update public.notifications set read_at=case when coalesce((payload->>'read')::boolean,true) then coalesce(read_at,now()) else null end,
      acknowledged_at=case when coalesce((payload->>'acknowledged')::boolean,false) then coalesce(acknowledged_at,now()) else acknowledged_at end
      where id=match[1]::bigint and recipient_id=actor.id;
    return jsonb_build_object('ok',true);
  end if;
  raise exception 'უცნობი monitoring route.' using errcode='22023';
end
$$;

revoke all on function public.monitoring_api(text,text,jsonb) from public,anon;
grant execute on function public.monitoring_api(text,text,jsonb) to authenticated;



