do $migration$
declare definition text;
begin
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,
 $old$if route='/branches' and method='POST' then
  insert into public.branches(name) values(btrim(payload->>'name')) returning id into result_id;$old$,
 $new$if route='/branches' and method='POST' then
  target_user=nullif(payload->>'supervisor_user_id','')::uuid;
  if target_user is null or not exists(select 1 from public.profiles where id=target_user and active and deleted_at is null and role='inspector') then raise exception 'აირჩიეთ მოქმედი ვაიზერი.'; end if;
  insert into public.branches(name,supervisor_user_id) values(btrim(payload->>'name'),target_user) returning id into result_id;
  insert into public.branch_assignment_history(branch_id,supervisor_id,changed_by,reason) values(result_id,target_user,auth.uid(),'assignment');$new$);
 definition=replace(definition,
 $old$update public.branches set name=case when payload?'name' then btrim(payload->>'name') else name end,active=case when payload?'active' then (payload->>'active')::boolean else active end where id=target returning id into result_id;$old$,
 $new$if payload?'supervisor_user_id' then
    target_user=nullif(payload->>'supervisor_user_id','')::uuid;
    if target_user is null or not exists(select 1 from public.profiles where id=target_user and active and deleted_at is null and role='inspector') then raise exception 'აირჩიეთ მოქმედი ვაიზერი.'; end if;
   end if;
   update public.branches set name=case when payload?'name' then btrim(payload->>'name') else name end,active=case when payload?'active' then (payload->>'active')::boolean else active end,supervisor_user_id=case when payload?'supervisor_user_id' then target_user else supervisor_user_id end where id=target returning id into result_id;
   if payload?'supervisor_user_id' then insert into public.branch_assignment_history(branch_id,supervisor_id,changed_by,reason) values(target,target_user,auth.uid(),'reassignment'); end if;$new$);
 execute definition;
end $migration$;

