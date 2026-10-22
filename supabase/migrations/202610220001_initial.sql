-- Run once on a NEW Supabase project. No application passwords are stored here.
begin;
create schema if not exists app_private;
revoke all on schema app_private from public,anon,authenticated;

create table public.profiles (
 id uuid primary key references auth.users(id),
 username text not null unique check(username ~ '^[a-z0-9_.-]{3,64}$'),
 name text not null check(length(btrim(name)) between 1 and 200),
 role text not null default 'inspector' check(role in ('admin','inspector')),
 active boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.branches (
 id integer generated always as identity primary key,
 name text not null check(length(btrim(name)) between 1 and 200),active boolean not null default true
);
create table public.questions (
 id integer generated always as identity primary key,
 text text not null check(length(btrim(text)) between 1 and 500),
 branch_id integer references public.branches(id), active boolean not null default true
);
create table public.inspections (
 id integer generated always as identity primary key,
 branch_id integer not null references public.branches(id), branch_name text not null,
 user_id uuid not null references public.profiles(id),user_name text not null,
 created_at timestamptz not null default now(), note text not null default '' check(length(note)<=2000),
 request_key uuid not null, unique(user_id,request_key)
);
create table public.answers (
 id bigint generated always as identity primary key,
 inspection_id integer not null references public.inspections(id),
 question_id integer not null references public.questions(id),question_text text not null,
 rating integer not null check(rating between 1 and 5),unique(inspection_id,question_id)
);
create table public.audit (
 id bigint generated always as identity primary key,user_id uuid references public.profiles(id),
 action text not null,target text not null,created_at timestamptz not null default now()
);
create index inspections_date_idx on public.inspections(created_at desc);
create index inspections_branch_date_idx on public.inspections(branch_id,created_at desc);
create index answers_inspection_idx on public.answers(inspection_id);
create index questions_branch_idx on public.questions(branch_id) where active;

-- Auth metadata is untrusted: a new account always starts inactive and as inspector.
create function app_private.on_auth_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,username,name,role,active)
 values(new.id,split_part(lower(new.email),'@',1),coalesce(nullif(btrim(new.raw_user_meta_data->>'name'),''),'მომხმარებელი'),'inspector',false);
 return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function app_private.on_auth_user();

create function app_private.is_active() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and active)
$$;
create function app_private.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and active and role='admin')
$$;
-- Policies may call these helpers; the private schema is not a Data API schema.
grant usage on schema app_private to authenticated;
revoke all on all functions in schema app_private from public,anon,authenticated;
grant execute on function app_private.is_active(),app_private.is_admin() to authenticated;

alter table public.profiles enable row level security;
alter table public.branches enable row level security;
alter table public.questions enable row level security;
alter table public.inspections enable row level security;
alter table public.answers enable row level security;
alter table public.audit enable row level security;
create policy profile_read on public.profiles for select to authenticated using ((id=auth.uid() and active) or app_private.is_admin());
create policy branch_read on public.branches for select to authenticated using (app_private.is_active() and (active or app_private.is_admin()));
create policy question_read on public.questions for select to authenticated using (app_private.is_active() and (active or app_private.is_admin()));
create policy inspection_read on public.inspections for select to authenticated using(app_private.is_admin());
create policy answer_read on public.answers for select to authenticated using(app_private.is_admin());
create policy audit_read on public.audit for select to authenticated using(app_private.is_admin());
revoke all on public.profiles,public.branches,public.questions,public.inspections,public.answers,public.audit from anon,authenticated;
grant select on public.profiles,public.branches,public.questions,public.inspections,public.answers,public.audit to authenticated;
-- All browser writes go through the checked transaction below, never direct table writes.
grant all on public.profiles,public.branches,public.questions,public.inspections,public.answers,public.audit to service_role;
grant usage,select on all sequences in schema public to service_role;

create function app_private.report_data(p_from date,p_to date,p_branch integer,p_export boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_from>p_to then raise exception 'დასაწყისი თარიღი დასასრულზე გვიანი ვერ იქნება.';end if;
 if p_export then
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into result from (
   select i.id,i.created_at,i.branch_name,i.user_name,a.question_text,a.rating,i.note
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
  select i.*,round(avg(a.rating),2) score,count(a.id) answer_count from filtered i join public.answers a on a.inspection_id=i.id group by i.id,i.branch_id,i.branch_name,i.user_id,i.user_name,i.created_at,i.note,i.request_key
 ), latest as (select * from scores order by created_at desc,id desc limit 200),
 stats as (select count(a.id) answers,round(avg(a.rating),2) score,count(*) filter(where a.rating<=2) issues from filtered i join public.answers a on a.inspection_id=i.id),
 bybranch as (select i.branch_id,i.branch_name,round(avg(a.rating),2) score,count(distinct i.id) inspections from filtered i join public.answers a on a.inspection_id=i.id group by i.branch_id,i.branch_name order by score)
 select jsonb_build_object('total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(latest) order by created_at desc,id desc) from latest),'[]'::jsonb),'stats',(select to_jsonb(stats) from stats),'byBranch',coalesce((select jsonb_agg(to_jsonb(bybranch) order by score) from bybranch),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.report_data(date,date,integer,boolean) from public,anon,authenticated;

create function public.app_api(route text,method text default 'GET',payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor public.profiles%rowtype;branch public.branches%rowtype;item jsonb;q record;
 target integer;target_user uuid;result_id integer;expected integer;name_value text;parts text[];result jsonb;
begin
 select * into actor from public.profiles where id=auth.uid() and active;
 if not found then raise exception 'წვდომა შეზღუდულია. მიმართეთ ადმინისტრატორს.' using errcode='42501';end if;
 if method not in ('GET','POST','PATCH') or jsonb_typeof(payload)<>'object' then raise exception 'არასწორი მოთხოვნა.';end if;
 if method<>'GET' then perform pg_advisory_xact_lock(61022001);end if;
 -- Recheck profile after acquiring the mutation lock (role/deactivation changes use the same lock).
 select * into actor from public.profiles where id=auth.uid() and active;
 if not found then raise exception 'ანგარიში გამორთულია.' using errcode='42501';end if;
 if route='/me' and method='GET' then return to_jsonb(actor);end if;
 if route='/catalog' and method='GET' then
  return jsonb_build_object('branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where active),'[]'::jsonb),'questions',coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from public.questions t where active),'[]'::jsonb));
 end if;
 if route='/inspections' and method='POST' then
  select id into result_id from public.inspections where user_id=actor.id and request_key=(payload->>'request_key')::uuid;
  if found then return jsonb_build_object('id',result_id);end if;
  select * into branch from public.branches where id=(payload->>'branch_id')::integer and active;
  if not found then raise exception 'აირჩიეთ მოქმედი ფილიალი.';end if;
  if jsonb_typeof(payload->'answers') is distinct from 'array' then raise exception 'შეავსეთ ყველა კითხვა.';end if;
  if jsonb_typeof(payload->'note') is distinct from 'string' or length(payload->>'note')>2000 then raise exception 'კომენტარი მაქსიმუმ 2000 სიმბოლო.';end if;
  select count(*) into expected from public.questions where active and (branch_id is null or branch_id=branch.id);
  if expected=0 or expected<>jsonb_array_length(payload->'answers') then raise exception 'კითხვები შეიცვალა ან პასუხები არასრულია. განაახლეთ სია.';end if;
  for item in select value from jsonb_array_elements(payload->'answers') loop
   if jsonb_typeof(item)<>'object' or jsonb_typeof(item->'question_id') is distinct from 'number' or coalesce(item->>'question_id','') !~ '^[0-9]{1,10}$' or jsonb_typeof(item->'rating') is distinct from 'number' or coalesce(item->>'rating','') !~ '^[1-5]$' then raise exception 'არასწორი შეფასება.';end if;
   if not exists(select 1 from public.questions where id=(item->>'question_id')::integer and active and (branch_id is null or branch_id=branch.id) and text=item->>'question_text') then raise exception 'კითხვები შეიცვალა. განაახლეთ სია.';end if;
  end loop;
  if (select count(distinct value->>'question_id') from jsonb_array_elements(payload->'answers'))<>expected then raise exception 'შეავსეთ ყველა კითხვა ერთხელ.';end if;
  insert into public.inspections(branch_id,branch_name,user_id,user_name,note,request_key) values(branch.id,branch.name,actor.id,actor.name,payload->>'note',(payload->>'request_key')::uuid) returning id into result_id;
  for item in select value from jsonb_array_elements(payload->'answers') loop
   insert into public.answers(inspection_id,question_id,question_text,rating) values(result_id,(item->>'question_id')::integer,item->>'question_text',(item->>'rating')::integer);
  end loop;
  insert into public.audit(user_id,action,target) values(actor.id,'inspection.create',result_id::text);
  return jsonb_build_object('id',result_id);
 end if;
 if actor.role<>'admin' then raise exception 'წვდომა მხოლოდ ადმინისტრატორისთვისაა.' using errcode='42501';end if;
 if route='/admin/catalog' and method='GET' then
  return jsonb_build_object('branches',coalesce((select jsonb_agg(to_jsonb(b) order by id) from public.branches b),'[]'::jsonb),'questions',coalesce((select jsonb_agg(to_jsonb(t) order by id) from (select q.*,b.name branch_name from public.questions q left join public.branches b on b.id=q.branch_id) t),'[]'::jsonb),'users',coalesce((select jsonb_agg(to_jsonb(p) order by created_at) from public.profiles p),'[]'::jsonb));
 end if;
 if route in ('/reports','/export') and method='GET' then return app_private.report_data(nullif(payload->>'from','')::date,nullif(payload->>'to','')::date,nullif(payload->>'branch','')::integer,route='/export');end if;
 if route ~ '^/reports/[0-9]+$' and method='GET' then
  target=split_part(route,'/',3)::integer;
  select to_jsonb(i)||jsonb_build_object('answers',coalesce((select jsonb_agg(jsonb_build_object('question_text',a.question_text,'rating',a.rating) order by a.id) from public.answers a where a.inspection_id=i.id),'[]'::jsonb)) into result from public.inspections i where id=target;
  if result is null then raise exception 'ანგარიში ვერ მოიძებნა.';end if;return result;
 end if;
 if route='/branches' and method='POST' then
  insert into public.branches(name) values(btrim(payload->>'name')) returning id into result_id;
 elsif route='/questions' and method='POST' then
  target=nullif(payload->>'branch_id','')::integer;
  if target is not null and not exists(select 1 from public.branches where id=target and active) then raise exception 'ფილიალი არ არსებობს.';end if;
  insert into public.questions(text,branch_id) values(btrim(payload->>'text'),target) returning id into result_id;
 elsif route ~ '^/(branches|questions)/[0-9]+$' and method='PATCH' then
  parts=string_to_array(route,'/');target=parts[3]::integer;
  if payload?'active' and jsonb_typeof(payload->'active')<>'boolean' then raise exception 'არასწორი სტატუსი.';end if;
  if parts[2]='branches' then
   update public.branches set name=case when payload?'name' then btrim(payload->>'name') else name end,active=case when payload?'active' then (payload->>'active')::boolean else active end where id=target returning id into result_id;
  else
   update public.questions set text=case when payload?'text' then btrim(payload->>'text') else text end,active=case when payload?'active' then (payload->>'active')::boolean else active end where id=target returning id into result_id;
  end if;
  if not found then raise exception 'ჩანაწერი ვერ მოიძებნა.';end if;
 elsif route ~ '^/users/[a-f0-9-]{36}$' and method='PATCH' then
  target_user=split_part(route,'/',3)::uuid;
  if payload?'password' then raise exception 'გამოიყენეთ მომხმარებლების მართვის დაცული ფუნქცია.';end if;
  if payload?'active' and jsonb_typeof(payload->'active')<>'boolean' then raise exception 'არასწორი სტატუსი.';end if;
  if target_user=actor.id and ((payload?'active' and (payload->>'active')::boolean=false) or (payload?'role' and payload->>'role'<>'admin')) then raise exception 'საკუთარი ადმინისტრატორის გათიშვა ან როლის შეცვლა დაუშვებელია.';end if;
  update public.profiles set name=case when payload?'name' then btrim(payload->>'name') else name end,role=case when payload?'role' then payload->>'role' else role end,active=case when payload?'active' then (payload->>'active')::boolean else active end where id=target_user;
  if not found then raise exception 'მომხმარებელი ვერ მოიძებნა.';end if;
  insert into public.audit(user_id,action,target) values(actor.id,'user.update',target_user::text);return jsonb_build_object('ok',true);
 else raise exception 'მოქმედება ვერ მოიძებნა.';
 end if;
 insert into public.audit(user_id,action,target) values(actor.id,route||'.'||method,result_id::text);
 return jsonb_build_object('id',result_id,'ok',true);
end $$;
revoke all on function public.app_api(text,text,jsonb) from public,anon;
grant execute on function public.app_api(text,text,jsonb) to authenticated;
commit;
