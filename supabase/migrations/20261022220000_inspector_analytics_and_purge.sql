do $migration$
declare definition text;
begin
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,$old$if actor.role<>'admin' then raise exception$old$,$new$if actor.role<>'admin' and not (method='GET' and (route in ('/reports','/issues','/branch-comparison','/analysis/catalog') or route ~ '^/reports/[0-9]+$')) then raise exception$new$);
 definition=replace(definition,$old$ if route='/admin/catalog' and method='GET' then$old$,$new$ if route='/analysis/catalog' and method='GET' then
  return jsonb_build_object('branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b),'[]'::jsonb),'questions',coalesce((select jsonb_agg(to_jsonb(t) order by t.id) from (select q.*,b.name branch_name from public.questions q left join public.branches b on b.id=q.branch_id) t),'[]'::jsonb));
 end if;
 if route='/admin/catalog' and method='GET' then$new$);
 definition=replace(definition,$old$^/reports/[0-9]+/(delete|restore)$$old$,$new$^/reports/[0-9]+/(delete|restore|purge)$$new$);
 execute definition;
 select pg_get_functiondef('app_private.manage_inspection(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,$old$ if method='PATCH' and route ~$old$,$new$ if method='POST' and route ~ '^/reports/[0-9]+/purge$' then
  if current_row.deleted_at is null then raise exception 'სამუდამოდ წაშლამდე ჩანაწერი წაშლილებში გადაიტანეთ.';end if;
  if payload->>'purge_confirmation' is distinct from target::text then raise exception 'დაადასტურეთ შემოწმების ნომერი.';end if;
  delete from app_private.inspection_history where inspection_id=target;
  delete from public.answers where inspection_id=target;
  delete from app_private.inspection_runs where user_id=current_row.user_id and request_key=current_row.request_key;
  delete from public.inspections where id=target;
  delete from public.audit where public.audit.target=target::text and public.audit.action like 'inspection.%';
  insert into public.audit(user_id,action,target) values(auth.uid(),'inspection.purge',target::text);
  return jsonb_build_object('ok',true);
 end if;
 if method='PATCH' and route ~$new$);
 execute definition;
end $migration$;
