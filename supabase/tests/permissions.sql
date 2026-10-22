-- Run only on an isolated development project. Data is rolled back, identity
-- sequences can still advance. supabase test db uses pgTAP for the outer result.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(1);
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-4000-8000-000000000001','test-admin@branch-check.invalid','{"name":"ტესტი ადმინისტრატორი","role":"admin"}'),
 ('00000000-0000-4000-8000-000000000002','test-inspector@branch-check.invalid','{"name":"ტესტი ინსპექტორი","role":"admin"}');
do $$ begin
 if exists(select 1 from public.profiles where id in ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002') and (role<>'inspector' or active)) then raise exception 'Untrusted metadata granted access';end if;
end $$;
update public.profiles set active=true,role=case when username='test-admin' then 'admin' else 'inspector' end where id in ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002');
insert into public.branches(name) values('RLS test branch'),('RLS second branch');
insert into public.questions(text,branch_id) values('RLS global question',null),('RLS second only',(select id from public.branches where name='RLS second branch'));
set local role authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$
declare b integer;q integer;saved integer;answer jsonb;payload jsonb;
begin
 if (select count(*) from public.inspections)<>0 then raise exception 'Inspector read inspections';end if;
 if (select count(*) from public.profiles)<>1 then raise exception 'Inspector read other profiles';end if;
 begin perform public.app_api('/issues');raise exception 'Inspector read issues';exception when insufficient_privilege then null;end;
 begin perform public.app_api('/reports');raise exception 'Inspector read reports';exception when insufficient_privilege then null;end;
 begin perform public.app_api('/users/00000000-0000-4000-8000-000000000002','PATCH','{"role":"admin"}');raise exception 'Inspector escalated privileges';exception when insufficient_privilege then null;end;
 begin update public.profiles set role='admin' where id=auth.uid();raise exception 'Direct role write allowed';exception when insufficient_privilege then null;end;
 begin perform public.app_finish_user(auth.uid(),auth.uid(),'admin');raise exception 'Service function exposed';exception when insufficient_privilege then null;end;
 select id into b from public.branches where name='RLS test branch';select id into q from public.questions where text='RLS global question';
 payload=jsonb_build_object('branch_id',b,'request_key','00000000-0000-4000-8000-000000000003','note','ტესტის კომენტარი','answers','[]'::jsonb);
 begin perform public.app_api('/inspections','POST',payload);raise exception 'TEST_EXPECTED_FAILURE';exception when raise_exception then if sqlerrm='TEST_EXPECTED_FAILURE' then raise;end if;end;
 answer=jsonb_build_object('question_id',q,'question_text','RLS global question','rating',2);payload=jsonb_set(payload,'{answers}',jsonb_build_array(answer));
 if public.app_api('/inspections/start','POST',payload)->>'started_at' is null then raise exception 'Start time missing';end if;
 if public.app_api('/inspections/start','POST',payload)<>public.app_api('/inspections/start','POST',payload) then raise exception 'Start not idempotent';end if;
 saved=(public.app_api('/inspections','POST',payload)->>'id')::integer;
 if (public.app_api('/inspections','POST',payload)->>'id')::integer<>saved then raise exception 'Idempotency failed';end if;
 payload=jsonb_set(payload,'{request_key}','"00000000-0000-4000-8000-000000000004"'::jsonb);payload=jsonb_set(payload,'{answers,0,rating}','6'::jsonb);
 begin perform public.app_api('/inspections','POST',payload);raise exception 'TEST_EXPECTED_FAILURE';exception when raise_exception then if sqlerrm='TEST_EXPECTED_FAILURE' then raise;end if;end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';
do $$
declare b integer;q integer;i integer;r jsonb;
begin
 if jsonb_typeof(public.app_api('/admin/catalog')->'questions')<>'array' then raise exception 'Administrator catalog failed to load';end if;
 if public.app_api('/me')->>'role'<>'admin' then raise exception 'Administrator profile failed to load';end if;
 if (public.app_api('/issues')->>'total')::integer<>1 or public.app_api('/issues')->'rows'->0->>'question_text'<>'RLS global question' then raise exception 'Issue detail missing';end if;
 if (public.app_api('/reports')->>'total')::integer<>1 then raise exception 'Incorrect report count';end if;
 select id into b from public.branches where name='RLS test branch';select id into q from public.questions where text='RLS global question';select id into i from public.inspections where request_key='00000000-0000-4000-8000-000000000003';
 perform public.app_api('/branches/'||b,'PATCH','{"name":"Renamed","active":false}');
 perform public.app_api('/questions/'||q,'PATCH','{"text":"Changed","active":false}');
 r=public.app_api('/reports/'||i);
 if r->>'started_at' is null or (r->>'duration_seconds')::integer<0 then raise exception 'Timing missing or invalid';end if;
 if r->>'branch_name'<>'RLS test branch' or r->'answers'->0->>'question_text'<>'RLS global question' then raise exception 'History was changed';end if;
 if jsonb_array_length(public.app_api('/export'))<>1 then raise exception 'Export count incorrect';end if;
 begin perform public.app_api('/users/00000000-0000-4000-8000-000000000001','PATCH','{"active":false}');raise exception 'TEST_EXPECTED_FAILURE';exception when raise_exception then if sqlerrm='TEST_EXPECTED_FAILURE' then raise;end if;end;
 perform public.app_api('/users/00000000-0000-4000-8000-000000000002','PATCH','{"active":false}');
end $$;
set local request.jwt.claims='{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';
do $$ begin
 if (select count(*) from public.branches)<>0 then raise exception 'Inactive user read catalog';end if;
 begin perform public.app_api('/catalog');raise exception 'Inactive user called RPC';exception when insufficient_privilege then null;end;
end $$;
reset role;
set local role anon;
do $$ begin
 begin perform public.app_api('/catalog');raise exception 'Anonymous called RPC';exception when insufficient_privilege then null;end;
 begin perform 1 from public.inspections;raise exception 'Anonymous read data';exception when insufficient_privilege then null;end;
end $$;
reset role;
select pass('RLS, roles, required answers, idempotency, history and export');
select * from finish();
rollback;
