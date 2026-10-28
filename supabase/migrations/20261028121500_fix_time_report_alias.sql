do $outer$
declare definition text;
begin
 select pg_get_functiondef('public.supervisor_time_api(text,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'from grouped)','from grouped g)');
 execute definition;
 select pg_get_functiondef('public.monitoring_report_api(jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'from grouped)','from grouped g)');
 execute definition;
end $outer$;

