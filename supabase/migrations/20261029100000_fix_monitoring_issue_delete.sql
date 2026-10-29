-- Qualify issue_id columns so Admin issue deletion is unambiguous in PL/pgSQL.
do $migration$
declare definition text;
begin
 select pg_get_functiondef('public.monitoring_api(text,text,jsonb)'::regprocedure) into definition;
 definition:=replace(definition,'delete from public.issue_actions where issue_id=issue.id;','delete from public.issue_actions ia where ia.issue_id=issue.id;');
 definition:=replace(definition,'delete from public.attachments where issue_id=issue.id;','delete from public.attachments att where att.issue_id=issue.id;');
 definition:=replace(definition,'delete from public.issue_change_requests where issue_id=issue.id;','delete from public.issue_change_requests cr where cr.issue_id=issue.id;');
 execute definition;
end $migration$;

