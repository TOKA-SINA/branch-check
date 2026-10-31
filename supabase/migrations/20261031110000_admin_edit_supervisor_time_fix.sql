do $outer$
declare
 definition text;
 old_update text:= $$  update public.supervisor_branch_time set entry_at=entry_value,exit_at=exit_value,updated_at=now() where id=item.id;$$;
 new_update text:= $$  if actor.role='admin' and payload ? 'branch_id' then
   select * into branch from public.branches where id=(payload->>'branch_id')::integer and active;
   if branch.id is null then raise exception 'აირჩიეთ მოქმედი ფილიალი.'; end if;
   if branch.supervisor_user_id is null then raise exception 'ფილიალს აქტიური ვაიზერი არ ჰყავს.'; end if;
   select * into supervisor from public.profiles where id=branch.supervisor_user_id and active and deleted_at is null and role='inspector';
   if supervisor.id is null then raise exception 'ფილიალს აქტიური ვაიზერი არ ჰყავს.'; end if;
  end if;
  if actor.role='admin' and payload ? 'supervisor_name' and length(btrim(payload->>'supervisor_name'))=0 then raise exception 'ვაიზერის სახელი და გვარი აუცილებელია.'; end if;
  update public.supervisor_branch_time
  set branch_id=case when actor.role='admin' and payload ? 'branch_id' then branch.id else item.branch_id end,
      supervisor_user_id=case when actor.role='admin' and payload ? 'branch_id' then supervisor.id else item.supervisor_user_id end,
      supervisor_name=case when actor.role='admin' and payload ? 'supervisor_name' then btrim(payload->>'supervisor_name') when actor.role='admin' and payload ? 'branch_id' then supervisor.name else item.supervisor_name end,
      entry_at=entry_value,exit_at=exit_value,updated_at=now() where id=item.id;$$;
 old_entry text:= $$  entry_value:=case when payload ? 'entry_at' then nullif(payload->>'entry_at','')::timestamptz else item.entry_at end;$$;
 new_entry text:= $$  if actor.role<>'admin' and (payload ? 'branch_id' or payload ? 'supervisor_name') then raise exception 'ფილიალისა და ვაიზერის მონაცემების შეცვლა მხოლოდ Admin-ს შეუძლია.' using errcode='42501'; end if;
  entry_value:=case when payload ? 'entry_at' then nullif(payload->>'entry_at','')::timestamptz else item.entry_at end;$$;
begin
 select pg_get_functiondef('public.supervisor_time_api(text,text,jsonb)'::regprocedure) into definition;
 if position(old_update in definition)=0 or position(old_entry in definition)=0 then raise exception 'supervisor_time_api PATCH block was not found'; end if;
 definition:=replace(definition,old_entry,new_entry);
 definition:=replace(definition,old_update,new_update);
 execute definition;
end $outer$;

