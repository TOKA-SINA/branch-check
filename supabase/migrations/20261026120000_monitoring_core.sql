-- Branch Check expansion: role-safe monitoring core.
-- Existing inspection tables/functions remain intact.

alter table public.profiles add column if not exists deleted_at timestamptz;
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','inspector','monitoring'));
alter table public.branches add column if not exists supervisor_user_id uuid references public.profiles(id);
create index if not exists branches_supervisor_idx on public.branches(supervisor_user_id);

create table if not exists public.branch_assignment_history (
 id bigint generated always as identity primary key,
 branch_id integer not null references public.branches(id),
 previous_supervisor_id uuid references public.profiles(id),
 supervisor_id uuid references public.profiles(id),
 changed_by uuid references public.profiles(id),
 reason text not null default 'assignment',
 created_at timestamptz not null default now()
);
create table if not exists public.monitoring_criteria (
 id bigint generated always as identity primary key,
 title text not null check (char_length(btrim(title)) between 1 and 500),
 severity text not null check (severity in ('light','important','critical')),
 penalty_amount numeric(12,2) not null check (penalty_amount>=0),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.monitoring_issues (
 id bigint generated always as identity primary key,
 branch_id integer not null references public.branches(id),
 criterion_id bigint not null references public.monitoring_criteria(id),
 created_by uuid references public.profiles(id),
 status text not null default 'in_progress' check(status in ('in_progress','waiting_for_closure','closed')),
 comment text check(comment is null or char_length(comment)<=4000),
 penalty_applied numeric(12,2) not null default 0 check(penalty_applied>=0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 closed_at timestamptz,
 closed_by uuid references public.profiles(id),
 deleted_at timestamptz
);
create index if not exists monitoring_issues_branch_created_idx on public.monitoring_issues(branch_id,created_at desc);
create index if not exists monitoring_issues_creator_created_idx on public.monitoring_issues(created_by,created_at desc);
create index if not exists monitoring_issues_status_idx on public.monitoring_issues(status);
create index if not exists monitoring_issues_criterion_idx on public.monitoring_issues(criterion_id);
create index if not exists monitoring_issues_branch_status_idx on public.monitoring_issues(branch_id,status);

create table if not exists public.issue_actions (
 id bigint generated always as identity primary key,
 issue_id bigint not null references public.monitoring_issues(id),
 actor_id uuid references public.profiles(id),
 action text not null,
 comment text,
 payload jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists issue_actions_issue_idx on public.issue_actions(issue_id,created_at desc);

create table if not exists public.issue_change_requests (
 id bigint generated always as identity primary key,
 issue_id bigint not null references public.monitoring_issues(id),
 requested_by uuid references public.profiles(id),
 request_type text not null check(request_type in ('edit','delete')),
 comment text not null check(char_length(btrim(comment)) between 1 and 4000),
 requested_payload jsonb not null default '{}'::jsonb,
 status text not null default 'pending' check(status in ('pending','approved','rejected','executed')),
 reviewed_by uuid references public.profiles(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 executed_at timestamptz
);
create index if not exists issue_change_requests_status_idx on public.issue_change_requests(status,created_at desc);
create index if not exists issue_change_requests_issue_idx on public.issue_change_requests(issue_id,created_at desc);

create table if not exists public.attachments (
 id bigint generated always as identity primary key,
 issue_id bigint not null references public.monitoring_issues(id),
 uploaded_by uuid references public.profiles(id),
 attachment_type text not null check(attachment_type in ('photo','document')),
 drive_file_id text not null,
 file_name text not null check(char_length(file_name) between 1 and 255),
 mime_type text not null,
 size_bytes bigint not null check(size_bytes>0),
 created_at timestamptz not null default now(),
 deleted_at timestamptz
);
create index if not exists attachments_issue_idx on public.attachments(issue_id,created_at);

create table if not exists public.notifications (
 id bigint generated always as identity primary key,
 recipient_id uuid not null references public.profiles(id),
 type text not null,
 related_entity_type text,
 related_entity_id text,
 title text not null,
 message text not null,
 read_at timestamptz,
 acknowledged_at timestamptz,
 created_at timestamptz not null default now()
);
create index if not exists notifications_recipient_idx on public.notifications(recipient_id,read_at,created_at desc);

create table if not exists public.supervisor_leave_requests (
 id bigint generated always as identity primary key,
 supervisor_id uuid not null references public.profiles(id),
 start_date date not null,
 end_date date not null,
 reason text,
 status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
 reviewed_by uuid references public.profiles(id),
 reviewed_at timestamptz,
 cancelled_at timestamptz,
 created_at timestamptz not null default now(),
 check(end_date>=start_date)
);
create index if not exists leave_supervisor_dates_idx on public.supervisor_leave_requests(supervisor_id,start_date,end_date);

create table if not exists public.weekly_compliance (
 id bigint generated always as identity primary key,
 branch_id integer not null references public.branches(id),
 week_start date not null,
 inspection_days integer not null default 0,
 exempt boolean not null default false,
 updated_at timestamptz not null default now(),
 unique(branch_id,week_start)
);

create or replace function app_private.touch_monitoring_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
drop trigger if exists monitoring_criteria_touch on public.monitoring_criteria;
create trigger monitoring_criteria_touch before update on public.monitoring_criteria for each row execute function app_private.touch_monitoring_updated_at();
drop trigger if exists monitoring_issues_touch on public.monitoring_issues;
create trigger monitoring_issues_touch before update on public.monitoring_issues for each row execute function app_private.touch_monitoring_updated_at();

create or replace function app_private.refresh_monitoring_penalty() returns trigger language plpgsql security definer set search_path=public,app_private as $$
declare month_start timestamptz:=date_trunc('month',now());
begin
 if new.penalty_amount is distinct from old.penalty_amount then
  update public.monitoring_issues
  set penalty_applied=new.penalty_amount,updated_at=now()
  where criterion_id=new.id and created_at>=month_start and created_at<month_start+interval '1 month' and deleted_at is null;
 end if;
 return new;
end $$;
drop trigger if exists monitoring_criteria_penalty_refresh on public.monitoring_criteria;
create trigger monitoring_criteria_penalty_refresh after update on public.monitoring_criteria for each row execute function app_private.refresh_monitoring_penalty();

create or replace function app_private.notify_user(recipient uuid, ntype text, entity_type text, entity_id text, ntitle text, nmessage text) returns void language sql security definer set search_path=public,app_private as $$
 insert into public.notifications(recipient_id,type,related_entity_type,related_entity_id,title,message)
 values(recipient,ntype,entity_type,entity_id,ntitle,nmessage);
$$;
create or replace function app_private.notify_admins(ntype text, entity_type text, entity_id text, ntitle text, nmessage text) returns void language plpgsql security definer set search_path=public,app_private as $$
declare p record;
begin
 for p in select id from public.profiles where role='admin' and active and deleted_at is null loop
  perform app_private.notify_user(p.id,ntype,entity_type,entity_id,ntitle,nmessage);
 end loop;
end $$;
create or replace function app_private.can_monitoring_issue(issue_branch integer, issue_creator uuid) returns boolean language sql stable security definer set search_path=public,app_private as $$
 select exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.deleted_at is null and p.role='admin')
 or exists(select 1 from public.profiles p where p.id=auth.uid() and p.active and p.deleted_at is null and p.role='monitoring' and p.id=issue_creator)
 or exists(select 1 from public.profiles p join public.branches b on b.supervisor_user_id=p.id where p.id=auth.uid() and p.active and p.deleted_at is null and p.role='inspector' and b.id=issue_branch);
$$;

create or replace function public.monitoring_api(route text, method text default 'GET', payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,app_private as $$
declare
 actor public.profiles%rowtype;
 issue public.monitoring_issues%rowtype;
 issue_id bigint;
 request public.issue_change_requests%rowtype;
 request_id bigint;
 branch public.branches%rowtype;
 criterion public.monitoring_criteria%rowtype;
 target_status text;
 match text[];
 page_no integer:=greatest(coalesce((payload->>'page')::integer,0),0);
 page_size integer:=least(greatest(coalesce((payload->>'page_size')::integer,50),1),100);
 from_date timestamptz;
 to_date timestamptz;
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
  from_date:=nullif(payload->>'from','')::timestamptz;
  to_date:=nullif(payload->>'to','')::timestamptz;
  return jsonb_build_object(
   'page',page_no,'page_size',page_size,
   'total',(select count(*) from public.monitoring_issues i join public.branches b on b.id=i.branch_id
    where i.deleted_at is null and (actor.role='admin' or (actor.role='monitoring' and i.created_by=actor.id) or (actor.role='inspector' and b.supervisor_user_id=actor.id))
    and (nullif(payload->>'status','') is null or i.status=payload->>'status')
    and (from_date is null or i.created_at>=from_date) and (to_date is null or i.created_at<to_date)),
   'rows',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select i.id,i.branch_id,b.name branch_name,i.criterion_id,c.title criterion_title,c.severity,i.created_by,p.name creator_name,
    i.status,i.comment,i.penalty_applied,i.created_at,i.updated_at,i.closed_at
    from public.monitoring_issues i
    join public.branches b on b.id=i.branch_id
    join public.monitoring_criteria c on c.id=i.criterion_id
    left join public.profiles p on p.id=i.created_by
    where i.deleted_at is null and (actor.role='admin' or (actor.role='monitoring' and i.created_by=actor.id) or (actor.role='inspector' and b.supervisor_user_id=actor.id))
    and (nullif(payload->>'status','') is null or i.status=payload->>'status')
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
   'severity',c.severity,'created_by',i.created_by,'creator_name',p.name,'status',i.status,'comment',i.comment,
   'penalty_applied',i.penalty_applied,'created_at',i.created_at,'updated_at',i.updated_at,'closed_at',i.closed_at,
   'actions',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.issue_actions a where a.issue_id=i.id),'[]'::jsonb),
   'attachments',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.issue_id=i.id and a.deleted_at is null),'[]'::jsonb)
  ) from public.monitoring_issues i join public.branches b on b.id=i.branch_id join public.monitoring_criteria c on c.id=i.criterion_id left join public.profiles p on p.id=i.created_by where i.id=issue_id);
 end if;

 if route='/monitoring/issues' and method='POST' then
  if actor.role not in ('admin','monitoring') then raise exception 'საკითხის დაფიქსირება მხოლოდ მონიტორინგს შეუძლია.' using errcode='42501'; end if;
  select * into branch from public.branches where id=(payload->>'branch_id')::integer and active;
  if branch.id is null then raise exception 'აირჩიეთ მოქმედი ფილიალი.'; end if;
  select * into criterion from public.monitoring_criteria where id=(payload->>'criterion_id')::bigint and active;
  if criterion.id is null then raise exception 'აირჩიეთ მოქმედი Monitoring criterion.'; end if;
  insert into public.monitoring_issues(branch_id,criterion_id,created_by,comment,penalty_applied)
  values(branch.id,criterion.id,actor.id,nullif(btrim(payload->>'comment'),''),criterion.penalty_amount)
  returning id into issue_id;
  insert into public.issue_actions(issue_id,actor_id,action,payload)
  values(issue_id,actor.id,'issue.created',jsonb_build_object('criterion_id',criterion.id,'branch_id',branch.id));
  if branch.supervisor_user_id is not null then perform app_private.notify_user(branch.supervisor_user_id,'issue.created','monitoring_issue',issue_id::text,'ახალი მონიტორინგის საკითხი','თქვენს ფილიალში ახალი საკითხი დაფიქსირდა.'); end if;
  perform app_private.notify_admins('issue.created','monitoring_issue',issue_id::text,'ახალი მონიტორინგის საკითხი','ახალი მონიტორინგის საკითხი დაფიქსირდა.');
  return jsonb_build_object('id',issue_id,'status','in_progress');
 end if;

 match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/status$');
 if match is not null and method='POST' then
  issue_id:=match[1]::bigint;
  target_status:=payload->>'status';
  select * into issue from public.monitoring_issues where id=issue_id and deleted_at is null;
  if issue.id is null or not app_private.can_monitoring_issue(issue.branch_id,issue.created_by) then raise exception 'საკითხზე წვდომა არ გაქვთ.' using errcode='42501'; end if;
  if target_status not in ('in_progress','waiting_for_closure','closed') then raise exception 'არასწორი სტატუსი.'; end if;
  if target_status='closed' and actor.role<>'admin' then raise exception 'საკითხის დახურვა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
  if target_status='waiting_for_closure' and actor.role not in ('admin','inspector') then raise exception 'დახურვის მოლოდინში გადაყვანა მხოლოდ ვაიზერს შეუძლია.' using errcode='42501'; end if;
  update public.monitoring_issues set status=target_status,closed_at=case when target_status='closed' then now() else null end,closed_by=case when target_status='closed' then actor.id else null end where id=issue_id;
  insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue_id,actor.id,'issue.'||target_status,jsonb_build_object('status',target_status));
  return jsonb_build_object('ok',true,'status',target_status);
 end if;

 match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/comment$');
 if match is not null and method='POST' then
  issue_id:=match[1]::bigint;
  select * into issue from public.monitoring_issues where id=issue_id and deleted_at is null;
  if issue.id is null or not app_private.can_monitoring_issue(issue.branch_id,issue.created_by) then raise exception 'საკითხზე წვდომა არ გაქვთ.' using errcode='42501'; end if;
  if nullif(btrim(payload->>'comment'),'') is null then raise exception 'კომენტარი სავალდებულოა.'; end if;
  insert into public.issue_actions(issue_id,actor_id,action,comment) values(issue_id,actor.id,'comment.added',btrim(payload->>'comment'));
  return jsonb_build_object('ok',true);
 end if;

 match:=regexp_match(route,'^/monitoring/issues/([0-9]+)/change-request$');
 if match is not null and method='POST' then
  issue_id:=match[1]::bigint;
  select * into issue from public.monitoring_issues where id=issue_id and deleted_at is null;
  if actor.role<>'monitoring' or issue.id is null or issue.created_by<>actor.id then raise exception 'მოთხოვნის შექმნის უფლება არ გაქვთ.' using errcode='42501'; end if;
  if payload->>'request_type' not in ('edit','delete') or nullif(btrim(payload->>'comment'),'') is null then raise exception 'მიუთითეთ მოთხოვნის ტიპი და კომენტარი.'; end if;
  insert into public.issue_change_requests(issue_id,requested_by,request_type,comment,requested_payload)
  values(issue_id,actor.id,payload->>'request_type',btrim(payload->>'comment'),coalesce(payload->'requested_payload','{}'::jsonb))
  returning id into request_id;
  insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue_id,actor.id,'issue.'||payload->>'request_type'||'_requested',jsonb_build_object('request_id',request_id));
  perform app_private.notify_admins('issue.change_requested','monitoring_issue',issue_id::text,'საკითხის ცვლილების მოთხოვნა','Monitoring მომხმარებელმა ცვლილება მოითხოვა.');
  return jsonb_build_object('id',request_id,'status','pending');
 end if;

 if route='/monitoring/change-requests' and method='GET' then
  if actor.role<>'admin' then raise exception 'წვდომა მხოლოდ Admin-ს აქვს.' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
   select r.*,i.branch_id,i.created_by,c.title criterion_title
   from public.issue_change_requests r join public.monitoring_issues i on i.id=r.issue_id join public.monitoring_criteria c on c.id=i.criterion_id
   where r.status='pending'
  ) x),'[]'::jsonb);
 end if;

 match:=regexp_match(route,'^/monitoring/change-requests/([0-9]+)/review$');
 if match is not null and method='POST' then
  if actor.role<>'admin' then raise exception 'წვდომა მხოლოდ Admin-ს აქვს.' using errcode='42501'; end if;
  request_id:=match[1]::bigint;
  if payload->>'status' not in ('approved','rejected') then raise exception 'არასწორი გადაწყვეტილება.'; end if;
  update public.issue_change_requests set status=payload->>'status',reviewed_by=actor.id,reviewed_at=now() where id=request_id and status='pending' returning issue_id into issue_id;
  if issue_id is null then raise exception 'მოთხოვნა ვერ მოიძებნა ან უკვე განხილულია.'; end if;
  insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue_id,actor.id,'issue.'||payload->>'status',jsonb_build_object('request_id',request_id));
  return jsonb_build_object('ok',true);
 end if;

 match:=regexp_match(route,'^/monitoring/change-requests/([0-9]+)/execute$');
 if match is not null and method='POST' then
  request_id:=match[1]::bigint;
  select r.* into request from public.issue_change_requests r where r.id=request_id and r.requested_by=actor.id and r.status='approved';
  if request.id is null then raise exception 'დამტკიცებული მოთხოვნა ვერ მოიძებნა.'; end if;
  select i.* into issue from public.monitoring_issues i where i.id=request.issue_id;
  if request.request_type='delete' then update public.monitoring_issues set deleted_at=now(),updated_at=now() where id=issue.id;
  else update public.monitoring_issues set comment=coalesce(request.requested_payload->>'comment',comment),updated_at=now() where id=issue.id; end if;
  update public.issue_change_requests set status='executed',executed_at=now() where id=request.id;
  insert into public.issue_actions(issue_id,actor_id,action,payload) values(issue.id,actor.id,'issue.'||request.request_type||'d',jsonb_build_object('request_id',request.id));
  return jsonb_build_object('ok',true);
 end if;

 if route='/notifications' and method='GET' then
  return coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from public.notifications n where n.recipient_id=actor.id),'[]'::jsonb);
 end if;
 match:=regexp_match(route,'^/notifications/([0-9]+)$');
 if match is not null and method='PATCH' then
  update public.notifications set read_at=case when coalesce((payload->>'read')::boolean,true) then coalesce(read_at,now()) else null end, acknowledged_at=case when coalesce((payload->>'acknowledged')::boolean,false) then coalesce(acknowledged_at,now()) else acknowledged_at end where id=match[1]::bigint and recipient_id=actor.id;
  return jsonb_build_object('ok',true);
 end if;

 raise exception 'უცნობი monitoring route.' using errcode='22023';
end $$;

revoke all on function public.monitoring_api(text,text,jsonb) from public,anon;
grant execute on function public.monitoring_api(text,text,jsonb) to authenticated;
revoke all on public.branch_assignment_history,public.monitoring_criteria,public.monitoring_issues,public.issue_actions,public.issue_change_requests,public.attachments,public.notifications,public.supervisor_leave_requests,public.weekly_compliance from anon,authenticated;
grant all on public.branch_assignment_history,public.monitoring_criteria,public.monitoring_issues,public.issue_actions,public.issue_change_requests,public.attachments,public.notifications,public.supervisor_leave_requests,public.weekly_compliance to service_role;
do $$ begin begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end; end $$;


create or replace function public.app_finish_user(actor_id uuid,target_id uuid,new_role text)
returns void language plpgsql security definer set search_path=public,app_private as $$
begin
 perform pg_advisory_xact_lock(61022001);
 if not exists(select 1 from public.profiles where id=actor_id and active and deleted_at is null and role='admin') then raise exception 'Administrator required' using errcode='42501'; end if;
 if new_role not in ('inspector','monitoring') then raise exception 'Invalid role'; end if;
 update public.profiles set role=new_role,active=true,deleted_at=null where id=target_id and active=false and role in ('inspector','monitoring');
 if not found then raise exception 'Inactive new account required'; end if;
 insert into public.audit(user_id,action,target) values(actor_id,'user.create',target_id::text);
end $$;
revoke all on function public.app_finish_user(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.app_finish_user(uuid,uuid,text) to service_role;


