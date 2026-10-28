do $outer$
declare
 definition text;
begin
 select pg_get_functiondef('public.supervisor_time_api(text,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,
  'min(t.entry_at) first_entry_at,max(t.exit_at) last_exit_at',
  'max(t.id) last_record_id,max(coalesce(t.exit_at,t.entry_at)) last_record_at');
 execute definition;
end $outer$;

