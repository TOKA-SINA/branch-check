do $outer$
declare
 definition text;
begin
 select pg_get_functiondef('public.supervisor_time_api(text,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,
  $$ raise exception 'უცნობი supervisor time route.' using errcode='22023';$$,
  $$ match:=regexp_match(route,'^/supervisor-time/([0-9]+)$');
 if match is not null and method='DELETE' then
  if actor.role<>'admin' then raise exception 'ჩანაწერის წაშლა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
  delete from public.supervisor_branch_time where id=match[1]::bigint;
  if not found then raise exception 'ჩანაწერი ვერ მოიძებნა.'; end if;
  return jsonb_build_object('id',match[1]::bigint,'ok',true);
 end if;
 raise exception 'უცნობი supervisor time route.' using errcode='22023';$$);
 execute definition;
end $outer$;

