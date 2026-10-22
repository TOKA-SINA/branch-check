-- Preserve the existing function grants and historical migration files.
-- The unused PL/pgSQL record q shadows the questions table alias q when
-- administrators load /admin/catalog after successful authentication.
do $$
declare definition text;
begin
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 if position('item jsonb;q record;' in definition)>0 then
  execute replace(definition,'item jsonb;q record;','item jsonb;');
 end if;
end $$;
