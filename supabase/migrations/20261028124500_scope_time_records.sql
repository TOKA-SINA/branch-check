do $outer$
declare definition text;
begin
 select pg_get_functiondef('public.supervisor_time_api(text,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,
  'where (actor.role=''admin'' or (t.entry_at at time zone ''Asia/Tbilisi'')::date=(now() at time zone ''Asia/Tbilisi'')::date)',
  'where (actor.role=''admin'' or (t.recorded_by=actor.id and (t.entry_at at time zone ''Asia/Tbilisi'')::date=(now() at time zone ''Asia/Tbilisi'')::date))');
 execute definition;
end $outer$;

