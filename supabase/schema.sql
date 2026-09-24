-- Run once in a NEW Supabase project's SQL Editor. See README for admin bootstrap.
create extension if not exists pgcrypto;
create extension if not exists pg_cron;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 48),
  username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
  member_code text not null unique,
  role text not null default 'member' check (role in ('member','admin')),
  status text not null default 'pending' check (status in ('pending','approved','rejected','suspended')),
  mood text not null default '☕',
  created_at timestamptz not null default now()
);

create or replace function public.is_approved() returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles where id = (select auth.uid()) and status = 'approved')
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles where id = (select auth.uid()) and status = 'approved' and role = 'admin')
$$;

create or replace function public.new_profile() returns trigger language plpgsql security definer set search_path = '' as $$
declare handle text;
begin
  handle := lower(coalesce(new.raw_user_meta_data->>'username',''));
  if handle !~ '^[a-z0-9_]{3,24}$' then raise exception 'Invalid username'; end if;
  insert into public.profiles(id,name,username,member_code)
  values(new.id,left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'),''),'New member'),48),handle,'RZ-'||upper(substr(replace(new.id::text,'-',''),1,10)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.new_profile();

create table public.rooms (
  id bigint generated always as identity primary key,
  slug text not null unique check (slug ~ '^[a-z0-9-]{2,32}$'),
  title text not null check (char_length(title) between 2 and 32),
  emoji text not null default '💬',
  retention_hours integer not null default 24 check (retention_hours between 1 and 720),
  is_active boolean not null default true,
  sort_order integer not null default 0
);
insert into public.rooms(slug,title,emoji,sort_order) values
('general','General','💬',1),('technical','Technical','🛠️',2),('random','Random','🎲',3),('food','Food','🍜',4);

create table public.messages (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  saved_at timestamptz,
  saved_by uuid references public.profiles(id) on delete set null
);
create index messages_room_recent on public.messages(room_id,created_at desc);
create index messages_expiry on public.messages(expires_at) where saved_at is null;

create or replace function public.set_message_expiry() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  if new.author_id <> (select auth.uid()) then raise exception 'Invalid author'; end if;
  select now() + make_interval(hours => r.retention_hours) into new.expires_at
  from public.rooms r where r.id = new.room_id and r.is_active;
  if new.expires_at is null then raise exception 'Room unavailable'; end if;
  new.created_at := now(); new.saved_at := null; new.saved_by := null;
  return new;
end $$;
create trigger before_message_insert before insert on public.messages for each row execute function public.set_message_expiry();

create or replace function public.save_message(p_id bigint) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  update public.messages set saved_at = now(), saved_by = (select auth.uid())
  where id = p_id and saved_at is null and expires_at > now();
  if not found then raise exception 'Message unavailable or already saved'; end if;
end $$;

create table public.vent_posts (
  id bigint generated always as identity primary key,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index vent_expiry on public.vent_posts(expires_at);
create schema if not exists private;
create table private.vent_identity (
  post_id bigint primary key references public.vent_posts(id) on delete cascade,
  author_id uuid not null references auth.users(id),
  submitted_at timestamptz not null default now()
);
create table private.identity_access_log (
  id bigint generated always as identity primary key,
  post_id bigint not null,
  admin_id uuid not null,
  reason text not null check (char_length(reason) between 12 and 500),
  accessed_at timestamptz not null default now()
);
revoke all on schema private from public, anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

create or replace function public.submit_vent(p_body text) returns void language plpgsql security definer set search_path = '' as $$
declare post_key bigint;
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  if char_length(trim(p_body)) not between 1 and 2000 then raise exception 'Post must be 1–2000 characters'; end if;
  insert into public.vent_posts(body) values(trim(p_body)) returning id into post_key;
  insert into private.vent_identity(post_id,author_id) values(post_key,(select auth.uid()));
end $$;

create or replace function public.review_vent_identity(p_id bigint,p_reason text)
returns table(author_id uuid,member_code text,name text,username text)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admin required'; end if;
  if char_length(trim(p_reason)) not between 12 and 500 then raise exception 'A specific reason is required'; end if;
  if not exists(select 1 from private.vent_identity where post_id = p_id) then raise exception 'Post unavailable'; end if;
  insert into private.identity_access_log(post_id,admin_id,reason) values(p_id,(select auth.uid()),trim(p_reason));
  return query select p.id,p.member_code,p.name,p.username from private.vent_identity v
  join public.profiles p on p.id = v.author_id where v.post_id = p_id;
end $$;

create table public.app_settings (
  id integer primary key default 1 check (id = 1),
  announcement text not null default '',
  button_enabled boolean not null default true,
  button_cooldown_minutes integer not null default 60 check (button_cooldown_minutes between 1 and 1440),
  default_sound text not null default 'soft' check (default_sound in ('soft','arcade','bubble','none'))
);
insert into public.app_settings(id) values(1);

create table public.global_events (
  id bigint generated always as identity primary key,
  actor_id uuid not null references public.profiles(id),
  kind text not null check (kind in ('confetti','balloons','disco','ducks','nothing','laser')),
  created_at timestamptz not null default now()
);
create index global_events_recent on public.global_events(created_at desc);
create or replace function public.press_button(p_kind text default null) returns text language plpgsql security definer set search_path = '' as $$
declare selected text; cooldown integer;
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  perform pg_catalog.pg_advisory_xact_lock(9211001);
  select button_cooldown_minutes into cooldown from public.app_settings where id = 1 and button_enabled;
  if cooldown is null then raise exception 'The button is taking a break'; end if;
  if not public.is_admin() and exists(select 1 from public.global_events where created_at > now() - make_interval(mins => cooldown)) then
    raise exception 'The button is cooling down';
  end if;
  if p_kind is not null and public.is_admin() and p_kind in ('confetti','balloons','disco','ducks','nothing','laser') then selected := p_kind;
  else selected := (array['confetti','balloons','disco','ducks','nothing','laser'])[1 + floor(random()*6)::int]; end if;
  insert into public.global_events(actor_id,kind) values((select auth.uid()),selected);
  return selected;
end $$;

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.messages enable row level security;
alter table public.vent_posts enable row level security;
alter table public.app_settings enable row level security;
alter table public.global_events enable row level security;

create policy profiles_read on public.profiles for select to authenticated using (id = (select auth.uid()) or public.is_approved());
create policy profiles_admin_edit on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy rooms_read on public.rooms for select to authenticated using (public.is_approved());
create policy rooms_admin_insert on public.rooms for insert to authenticated with check (public.is_admin());
create policy rooms_admin_edit on public.rooms for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy messages_read on public.messages for select to authenticated using (public.is_approved() and (saved_at is not null or expires_at > now()));
create policy messages_insert on public.messages for insert to authenticated with check (public.is_approved() and author_id = (select auth.uid()));
create policy messages_delete on public.messages for delete to authenticated using (public.is_admin() or author_id = (select auth.uid()));
create policy vent_read on public.vent_posts for select to authenticated using (public.is_approved() and expires_at > now());
create policy vent_delete on public.vent_posts for delete to authenticated using (public.is_admin());
create policy settings_read on public.app_settings for select to authenticated using (public.is_approved());
create policy settings_admin_edit on public.app_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy events_read on public.global_events for select to authenticated using (public.is_approved());

revoke all on function public.new_profile() from public, anon, authenticated;
grant execute on function public.is_approved(),public.is_admin(),public.save_message(bigint),public.submit_vent(text),public.review_vent_identity(bigint,text),public.press_button(text) to authenticated;

alter publication supabase_realtime add table public.messages,public.vent_posts,public.global_events,public.rooms,public.app_settings,public.profiles;

-- Delete expired posts hourly; saved messages remain until an admin deletes them.
create or replace function public.cleanup_rzyn() returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.messages where saved_at is null and expires_at <= now();
  delete from public.vent_posts where expires_at <= now();
  delete from public.global_events where created_at < now() - interval '7 days';
end $$;
revoke all on function public.cleanup_rzyn() from public,anon,authenticated;
select cron.schedule('rzyn-expiry','17 * * * *', 'select public.cleanup_rzyn()');
