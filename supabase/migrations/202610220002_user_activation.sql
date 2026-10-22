begin;
-- Only the Edge Function's server-side service_role client may call this.
create function public.app_finish_user(actor_id uuid,target_id uuid,new_role text)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(61022001);
 if not exists(select 1 from public.profiles where id=actor_id and active and role='admin') then raise exception 'Administrator required' using errcode='42501';end if;
 if new_role not in ('admin','inspector') then raise exception 'Invalid role';end if;
 update public.profiles set role=new_role,active=true where id=target_id and active=false and role='inspector';
 if not found then raise exception 'Inactive new account required';end if;
 insert into public.audit(user_id,action,target) values(actor_id,'user.create',target_id::text);
end $$;
revoke all on function public.app_finish_user(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.app_finish_user(uuid,uuid,text) to service_role;
commit;
