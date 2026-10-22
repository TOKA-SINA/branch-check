alter table public.inspections add column revision integer not null default 1;
alter table public.inspections add column deleted_at timestamptz;
create table app_private.inspection_history (
 id bigint generated always as identity primary key,
 inspection_id integer not null references public.inspections(id),
 actor_id uuid not null references public.profiles(id),
 action text not null, snapshot jsonb not null, created_at timestamptz not null default now()
);
alter table app_private.inspection_history enable row level security;
revoke all on app_private.inspection_history from public,anon,authenticated;
create function app_private.manage_inspection(route text,method text,payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare target integer; current_row public.inspections%rowtype; answer jsonb; result jsonb; action text;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and active and role='admin') then raise exception 'წვდომა მხოლოდ ადმინისტრატორისთვისაა.' using errcode='42501';end if;
 if route='/deleted-inspections' and method='GET' then
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.deleted_at desc,x.id desc) from (select id,branch_name,user_name,created_at,deleted_at,revision from public.inspections where deleted_at is not null order by deleted_at desc,id desc limit 200) x),'[]'::jsonb);
 end if;
 target=split_part(route,'/',3)::integer;
 select * into current_row from public.inspections where id=target for update;
 if not found then raise exception 'შემოწმება ვერ მოიძებნა.';end if;
 if payload->>'revision' is null or (payload->>'revision')::integer<>current_row.revision then raise exception 'ჩანაწერი უკვე შეიცვალა. გახსენით ხელახლა.';end if;
 if method='PATCH' and route ~ '^/reports/[0-9]+$' then
  action='inspection.edit';
  if current_row.deleted_at is not null then raise exception 'ჯერ აღადგინეთ წაშლილი შემოწმება.';end if;
  if jsonb_typeof(payload->'note') is distinct from 'string' or length(payload->>'note')>2000 then raise exception 'კომენტარი მაქსიმუმ 2000 სიმბოლო.';end if;
  if jsonb_typeof(payload->'answers') is distinct from 'array' then raise exception 'შეავსეთ ყველა კრიტერიუმი.';end if;
  if jsonb_array_length(payload->'answers')<>(select count(*) from public.answers where inspection_id=target) or (select count(distinct value->>'question_id') from jsonb_array_elements(payload->'answers'))<>jsonb_array_length(payload->'answers') then raise exception 'შეავსეთ ყველა კრიტერიუმი ერთხელ.';end if;
  for answer in select value from jsonb_array_elements(payload->'answers') loop
   if jsonb_typeof(answer->'question_id') is distinct from 'number' or coalesce(answer->>'question_id','') !~ '^[0-9]{1,10}$' or jsonb_typeof(answer->'rating') is distinct from 'number' or coalesce(answer->>'rating','') !~ '^[1-5]$' then raise exception 'შეფასება უნდა იყოს 1–5 ქულა.';end if;
   if not exists(select 1 from public.answers where inspection_id=target and question_id=(answer->>'question_id')::integer) then raise exception 'კრიტერიუმები არ ემთხვევა ამ შემოწმებას.';end if;
  end loop;
 elsif method='POST' and route ~ '^/reports/[0-9]+/delete$' and current_row.deleted_at is null then action='inspection.delete';
 elsif method='POST' and route ~ '^/reports/[0-9]+/restore$' and current_row.deleted_at is not null then action='inspection.restore';
 else raise exception 'დაუშვებელი მოქმედება.';end if;
 select to_jsonb(current_row)||jsonb_build_object('answers',(select jsonb_agg(to_jsonb(a) order by a.id) from public.answers a where a.inspection_id=target)) into result;
 insert into app_private.inspection_history(inspection_id,actor_id,action,snapshot) values(target,auth.uid(),action,result);
 if action='inspection.edit' then
  for answer in select value from jsonb_array_elements(payload->'answers') loop
   update public.answers set rating=(answer->>'rating')::integer where inspection_id=target and question_id=(answer->>'question_id')::integer;
  end loop;
  update public.inspections set note=payload->>'note',revision=revision+1 where id=target;
 else
  update public.inspections set deleted_at=case when action='inspection.delete' then now() else null end,revision=revision+1 where id=target;
 end if;
 insert into public.audit(user_id,action,target) values(auth.uid(),action,target::text);
 return jsonb_build_object('ok',true);
end $$;
revoke all on function app_private.manage_inspection(text,text,jsonb) from public,anon,authenticated;
do $migration$
declare definition text;
begin
 select pg_get_functiondef('app_private.report_data(date,date,integer,boolean)'::regprocedure) into definition;
 definition=replace(definition,'where (p_from','where i.deleted_at is null and (p_from');
 definition=replace(definition,'i.request_key,i.started_at,i.duration_seconds','i.request_key,i.started_at,i.duration_seconds,i.revision,i.deleted_at');
 execute definition;
 select pg_get_functiondef('app_private.branch_comparison(jsonb)'::regprocedure) into definition;
 definition=replace(definition,'where (nullif(payload','where i.deleted_at is null and (nullif(payload');
 execute definition;
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,$old$ if route='/branch-comparison'$old$,$new$ if route='/deleted-inspections' or (route ~ '^/reports/[0-9]+$' and method='PATCH') or route ~ '^/reports/[0-9]+/(delete|restore)$' then return app_private.manage_inspection(route,method,payload);end if;
 if route='/branch-comparison'$new$);
 definition=replace(definition,'where a.rating<=2','where i.deleted_at is null and a.rating<=2');
 definition=replace(definition,$old$jsonb_build_object('question_text',a.question_text,'rating',a.rating)$old$,$new$jsonb_build_object('question_id',a.question_id,'question_text',a.question_text,'rating',a.rating)$new$);
 definition=replace(definition,'from public.inspections i where id=target','from public.inspections i where id=target and deleted_at is null');
 execute definition;
end $migration$;
