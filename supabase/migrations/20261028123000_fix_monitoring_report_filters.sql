do $outer$
declare definition text;
begin
 select pg_get_functiondef('public.monitoring_report_api(jsonb)'::regprocedure) into definition;
 if position('criterion_id bigint; branch_id integer;' in definition)>0 then
  definition:=replace(definition,'criterion_id bigint; branch_id integer;','filter_criterion_id bigint; filter_branch_id integer;');
  definition:=replace(definition,'criterion_id:=nullif(payload->>''criterion'','''')::bigint;','filter_criterion_id:=nullif(payload->>''criterion'','''')::bigint;');
  definition:=replace(definition,'branch_id:=nullif(payload->>''branch'','''')::integer;','filter_branch_id:=nullif(payload->>''branch'','''')::integer;');
  definition:=replace(definition,'(branch_id is null or i.branch_id=branch_id)','(filter_branch_id is null or i.branch_id=filter_branch_id)');
  definition:=replace(definition,'(criterion_id is null or i.criterion_id=criterion_id)','(filter_criterion_id is null or i.criterion_id=filter_criterion_id)');
 end if;
 execute definition;
end $outer$;

