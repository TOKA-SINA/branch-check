-- Isolated CI database only; all fixtures roll back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(1);
insert into auth.users(id,email,raw_user_meta_data) values('00000000-0000-4000-8000-000000000091','comparison-admin@branch-check.invalid','{}'),('00000000-0000-4000-8000-000000000092','comparison-inspector@branch-check.invalid','{}');
update public.profiles set active=true,role=case when id='00000000-0000-4000-8000-000000000091' then 'admin' else 'inspector' end where id in ('00000000-0000-4000-8000-000000000091','00000000-0000-4000-8000-000000000092');
insert into public.branches(name) values('comparison A'),('comparison B'),('comparison C'),('comparison empty');
insert into public.questions(text) values('comparison criterion one'),('comparison criterion two');
insert into public.inspections(branch_id,branch_name,user_id,user_name,note,request_key,created_at)
select b.id,b.name,'00000000-0000-4000-8000-000000000092','Inspector','',gen_random_uuid(),'2026-01-01'::timestamptz+n*interval '1 day'
from public.branches b cross join lateral generate_series(1,case b.name when 'comparison A' then 10 when 'comparison B' then 7 when 'comparison C' then 9 else 0 end) n;
insert into public.answers(inspection_id,question_id,question_text,rating)
select i.id,q.id,q.text,case when q.text='comparison criterion two' then 2 when i.branch_name='comparison A' and i.created_at<'2026-01-05' then 1 else 5 end
from public.inspections i cross join public.questions q where q.text like 'comparison criterion%';
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000091';
set local role authenticated;
do $$ declare r jsonb;q1 text;q2 text;a jsonb;begin
 select id::text into q1 from public.questions where text='comparison criterion one';select id::text into q2 from public.questions where text='comparison criterion two';
 r=public.app_api('/branch-comparison','GET',jsonb_build_object('balanced','true','criteria',q1));
 if (r->>'common_count')::integer<>7 or (r->>'branch_count')::integer<>3 or (r->>'total_selected')::integer<>21 then raise exception 'Unequal sample or zero branch was included: %',r;end if;
 for a in select value from jsonb_array_elements(r->'rows') loop
  if (a->>'inspections')::integer<>7 or (a->>'score')::numeric<>5 then raise exception 'Did not select newest seven: %',a;end if;
 end loop;
 r=public.app_api('/branch-comparison','GET',jsonb_build_object('balanced','true','criteria',q1||','||q2));
 if (r->'rows'->0->>'score')::numeric<>3.5 then raise exception 'Multiple criteria average is wrong';end if;
 r=public.app_api('/branch-comparison','GET','{"balanced":"false","from":"2026-01-09"}');
 if (r->>'total_selected')::integer<>5 then raise exception 'Date filter wrong: %',r;end if;
 r=public.app_api('/branch-comparison','GET','{"balanced":"true","from":"2026-01-09"}');
 if (r->>'common_count')::integer<>2 or (r->>'total_selected')::integer<>4 then raise exception 'Date-filtered balancing wrong: %',r;end if;
end $$;
set local request.jwt.claim.sub='00000000-0000-4000-8000-000000000092';
do $$ begin
 if (public.app_api('/branch-comparison')->>'branch_count')::integer<>3 then raise exception 'Inspector comparison unavailable';end if;
end $$;
reset role;
select pass('Newest equal branch samples, zero branches, dates, multiple criteria and role isolation');
select * from finish();
rollback;
