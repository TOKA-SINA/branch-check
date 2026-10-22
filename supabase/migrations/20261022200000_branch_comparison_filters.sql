create function app_private.branch_comparison(payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb; criteria integer[]; balanced boolean=coalesce((payload->>'balanced')::boolean,false);
begin
 if nullif(payload->>'from','')::date > nullif(payload->>'to','')::date then raise exception 'შეამოწმეთ თარიღების პერიოდი.';end if;
 if nullif(payload->>'criteria','') is not null then
  if length(payload->>'criteria')>2000 or payload->>'criteria' !~ '^[0-9]+(,[0-9]+)*$' then raise exception 'შეამოწმეთ კრიტერიუმების არჩევანი.';end if;
  criteria=string_to_array(payload->>'criteria',',')::integer[];
 end if;
 with ranked as (
  select i.*,row_number() over(partition by i.branch_id order by i.created_at desc,i.id desc) position
  from public.inspections i
  where (nullif(payload->>'from','') is null or i.created_at >= (nullif(payload->>'from','')::date::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'to','') is null or i.created_at < ((nullif(payload->>'to','')::date+1)::timestamp at time zone 'Asia/Tbilisi'))
   and (nullif(payload->>'branch','') is null or i.branch_id=(payload->>'branch')::integer)
 ), counts as (select branch_id,count(*) n from ranked group by branch_id),
 common as (select coalesce(min(n),0) n,count(*) branches from counts),
 picked as (select r.* from ranked r where not balanced or r.position<=(select n from common)),
 grouped as (
  select p.branch_id,coalesce(b.name,max(p.branch_name)) branch_name,
   round(avg(a.rating),2) score,count(distinct p.id) inspections,
   count(distinct p.id) filter(where a.id is not null) rated_inspections,
   count(a.id) answers,count(a.id) filter(where a.rating<=2) issues
  from picked p left join public.branches b on b.id=p.branch_id
  left join public.answers a on a.inspection_id=p.id and (criteria is null or a.question_id=any(criteria))
  group by p.branch_id,b.name
 )
 select jsonb_build_object('common_count',(select n from common),'branch_count',(select branches from common),
  'total_selected',(select count(*) from picked),
  'rows',coalesce((select jsonb_agg(to_jsonb(grouped) order by score desc nulls last,branch_name) from grouped),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function app_private.branch_comparison(jsonb) from public,anon,authenticated;
do $migration$
declare definition text;
begin
 select pg_get_functiondef('public.app_api(text,text,jsonb)'::regprocedure) into definition;
 definition=replace(definition,$old$ if route='/issues' and method='GET' then$old$,$new$ if route='/branch-comparison' and method='GET' then return app_private.branch_comparison(payload);end if;
 if route='/issues' and method='GET' then$new$);
 execute definition;
end $migration$;
