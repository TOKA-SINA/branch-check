create or replace function app_private.touch_monitoring_updated_at() returns trigger language plpgsql set search_path=public,app_private as $$ begin new.updated_at=now(); return new; end $$;

