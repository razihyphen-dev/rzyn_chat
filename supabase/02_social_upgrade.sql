-- Run AFTER schema.sql on a fresh RZYN project. This file is a one-time upgrade.
-- All client-facing tables use Row Level Security. Keep service-role keys on Netlify only.

alter table public.profiles add column xp integer not null default 0 check (xp >= 0);
alter table public.profiles add column birthday_month smallint check (birthday_month between 1 and 12);
alter table public.profiles add column birthday_day smallint check (birthday_day between 1 and 31);
alter table public.rooms add column is_private boolean not null default false;
alter table public.messages add column reply_to_id bigint references public.messages(id) on delete set null;
alter table public.app_settings add column default_wallpaper text not null default 'aurora'
  check (default_wallpaper in ('aurora','afterhours','ocean','solar','midnight','candy'));
alter table public.app_settings add column mascot_enabled boolean not null default true;
alter table public.app_settings add column push_enabled boolean not null default true;
alter table public.app_settings add column polls_enabled boolean not null default true;
alter table public.app_settings add column gif_enabled boolean not null default true;
alter table public.app_settings add column xp_enabled boolean not null default true;

create table public.room_members (
  room_id bigint not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  can_read boolean not null default true,
  can_post boolean not null default true,
  primary key(room_id,user_id)
);
alter table public.room_members enable row level security;
create policy room_members_admin_read on public.room_members for select to authenticated using (public.is_admin());
create policy room_members_admin_insert on public.room_members for insert to authenticated with check (public.is_admin());
create policy room_members_admin_update on public.room_members for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy room_members_admin_delete on public.room_members for delete to authenticated using (public.is_admin());

create or replace function public.can_read_room(p_room bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_approved() and exists (
    select 1 from public.rooms r left join public.room_members rm
      on rm.room_id = r.id and rm.user_id = (select auth.uid())
    where r.id = p_room and (
      public.is_admin() or (r.is_active and
      (case when r.is_private then rm.can_read is true else coalesce(rm.can_read,true) end))
    )
  )
$$;
create or replace function public.can_post_room(p_room bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.can_read_room(p_room) and (
    public.is_admin() or coalesce((select rm.can_post from public.room_members rm
      where rm.room_id = p_room and rm.user_id = (select auth.uid())),true)
  )
$$;
grant execute on function public.can_read_room(bigint),public.can_post_room(bigint) to authenticated;

drop policy rooms_read on public.rooms;
create policy rooms_read on public.rooms for select to authenticated
using (public.can_read_room(id) or public.is_admin());
drop policy messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
using (public.can_read_room(room_id) and (saved_at is not null or expires_at > now()));
drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
with check (public.can_post_room(room_id) and author_id = (select auth.uid()));
create or replace function public.set_message_expiry() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  if new.author_id <> (select auth.uid()) then raise exception 'Invalid author'; end if;
  if new.body like '/gif %' and not (select gif_enabled from public.app_settings where id=1)
    then raise exception 'GIFs are paused'; end if;
  select now()+make_interval(hours=>r.retention_hours) into new.expires_at
    from public.rooms r where r.id=new.room_id and r.is_active;
  if new.expires_at is null then raise exception 'Room unavailable'; end if;
  new.created_at:=now();new.saved_at:=null;new.saved_by:=null;
  return new;
end $$;

create or replace function public.validate_reply() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.reply_to_id is not null and not exists(
    select 1 from public.messages m where m.id = new.reply_to_id and m.room_id = new.room_id
      and (m.saved_at is not null or m.expires_at > now())
  ) then raise exception 'Reply target unavailable in this room'; end if;
  return new;
end $$;
create trigger validate_message_reply before insert on public.messages
for each row execute function public.validate_reply();

create table public.message_reactions (
  message_id bigint not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('😂','🔥','💀','👀','❤️','🫡','☕')),
  created_at timestamptz not null default now(),
  primary key(message_id,user_id,emoji)
);
create index reactions_message on public.message_reactions(message_id);
alter table public.message_reactions enable row level security;
create policy reactions_read on public.message_reactions for select to authenticated using (
  exists(select 1 from public.messages m where m.id=message_id and public.can_read_room(m.room_id)
    and (m.saved_at is not null or m.expires_at>now()))
);
create policy reactions_insert on public.message_reactions for insert to authenticated with check (
  user_id=(select auth.uid()) and exists(select 1 from public.messages m
    where m.id=message_id and public.can_post_room(m.room_id) and (m.saved_at is not null or m.expires_at>now()))
);
create policy reactions_delete on public.message_reactions for delete to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

create table public.fame_entries (
  id bigint generated always as identity primary key,
  message_id bigint unique references public.messages(id) on delete set null,
  room_id bigint not null references public.rooms(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null,
  admirer_count integer not null default 3,
  featured_at timestamptz not null default now()
);
alter table public.fame_entries enable row level security;
create policy fame_read on public.fame_entries for select to authenticated using (public.can_read_room(room_id));
create policy fame_admin_delete on public.fame_entries for delete to authenticated using (public.is_admin());
create or replace function public.remove_fame_on_manual_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null then
    delete from public.fame_entries where message_id=old.id;
  end if;
  return old;
end $$;
create trigger remove_fame_manual before delete on public.messages
for each row execute function public.remove_fame_on_manual_delete();
create or replace function public.update_fame() returns trigger
language plpgsql security definer set search_path = '' as $$
declare m record; admirers integer;
begin
  select * into m from public.messages where id=new.message_id;
  select count(distinct user_id) into admirers from public.message_reactions where message_id=new.message_id;
  if admirers>=3 then
    insert into public.fame_entries(message_id,room_id,author_id,body,admirer_count)
    values(m.id,m.room_id,m.author_id,m.body,admirers)
    on conflict(message_id) do update set admirer_count=excluded.admirer_count;
  end if;
  return new;
end $$;
create trigger fame_reaction after insert on public.message_reactions
for each row execute function public.update_fame();

create table public.polls (
  id bigint generated always as identity primary key,
  room_id bigint not null references public.rooms(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  question text not null check (char_length(question) between 5 and 160),
  options jsonb not null check (jsonb_typeof(options)='array' and jsonb_array_length(options) between 2 and 4),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '24 hours'
);
create or replace function public.normalize_poll() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not (select polls_enabled from public.app_settings where id=1) then raise exception 'Polls are paused'; end if;
  if (select count(*) from public.polls where author_id=new.author_id and created_at>now()-interval '1 day')>=5
    then raise exception 'Five polls per day is plenty'; end if;
  if exists(select 1 from jsonb_array_elements(new.options) o
    where jsonb_typeof(o.value)<>'string' or char_length(o.value #>> '{}') not between 1 and 80) then
    raise exception 'Poll options must be short text';
  end if;
  new.created_at:=now(); new.expires_at:=now()+interval '24 hours';
  return new;
end $$;
create trigger normalize_poll_insert before insert on public.polls for each row execute function public.normalize_poll();
create index polls_room_recent on public.polls(room_id,created_at desc);
create table public.poll_votes (
  poll_id bigint not null references public.polls(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  option_index integer not null check (option_index between 0 and 3),
  created_at timestamptz not null default now(),
  primary key(poll_id,user_id)
);
create or replace function public.validate_poll_vote() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.polls p where p.id=new.poll_id
    and p.expires_at>now() and new.option_index<jsonb_array_length(p.options)
    and public.can_post_room(p.room_id)) then raise exception 'Poll is closed or option invalid'; end if;
  return new;
end $$;
create trigger validate_vote before insert or update on public.poll_votes
for each row execute function public.validate_poll_vote();
alter table public.polls enable row level security;
alter table public.poll_votes enable row level security;
create policy polls_read on public.polls for select to authenticated using (public.can_read_room(room_id));
create policy polls_insert on public.polls for insert to authenticated
with check (author_id=(select auth.uid()) and public.can_post_room(room_id));
create policy polls_delete on public.polls for delete to authenticated using (public.is_admin());
create policy poll_votes_read on public.poll_votes for select to authenticated using (
  exists(select 1 from public.polls p where p.id=poll_id and public.can_read_room(p.room_id))
);
create policy poll_votes_insert on public.poll_votes for insert to authenticated with check (user_id=(select auth.uid()));
create policy poll_votes_update on public.poll_votes for update to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));

create table public.quote_nominations (
  id bigint generated always as identity primary key,
  quote text not null check (char_length(quote) between 4 and 240),
  nominator_id uuid not null references public.profiles(id) on delete cascade,
  quote_day date not null default (now() at time zone 'Asia/Riyadh')::date,
  created_at timestamptz not null default now()
);
create or replace function public.normalize_quote() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.quote_nominations where nominator_id=new.nominator_id
    and quote_day=(now() at time zone 'Asia/Riyadh')::date)>=5 then raise exception 'Five quotes per day is plenty'; end if;
  new.quote_day:=(now() at time zone 'Asia/Riyadh')::date; new.created_at:=now(); return new;
end $$;
create trigger normalize_quote_insert before insert on public.quote_nominations
for each row execute function public.normalize_quote();
create table public.quote_votes (
  quote_id bigint not null references public.quote_nominations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key(quote_id,user_id)
);
alter table public.quote_nominations enable row level security;
alter table public.quote_votes enable row level security;
create policy quotes_read on public.quote_nominations for select to authenticated using (public.is_approved());
create policy quotes_insert on public.quote_nominations for insert to authenticated
with check (public.is_approved() and nominator_id=(select auth.uid()));
create policy quotes_delete on public.quote_nominations for delete to authenticated using (public.is_admin());
create policy quote_votes_read on public.quote_votes for select to authenticated using (public.is_approved());
create policy quote_votes_insert on public.quote_votes for insert to authenticated
with check (public.is_approved() and user_id=(select auth.uid()));
create policy quote_votes_delete on public.quote_votes for delete to authenticated
using (user_id=(select auth.uid()) or public.is_admin());

create table public.stickers (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 2 and 40),
  emoji text not null check (char_length(emoji) between 1 and 12),
  image_url text check (image_url is null or (image_url ~ '^https://' and char_length(image_url)<500)),
  enabled boolean not null default true
);
insert into public.stickers(name,emoji) values
('Coffee mission','☕'),('Office duck','🦆'),('It works','🎉'),('Send help','🫠'),('On site','🚗');
alter table public.stickers enable row level security;
create policy stickers_read on public.stickers for select to authenticated using (public.is_approved() and (enabled or public.is_admin()));
create policy stickers_admin_insert on public.stickers for insert to authenticated with check (public.is_admin());
create policy stickers_admin_update on public.stickers for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy stickers_admin_delete on public.stickers for delete to authenticated using (public.is_admin());

alter table public.app_settings drop constraint if exists app_settings_default_sound_check;
alter table public.app_settings add constraint app_settings_default_sound_check
  check (default_sound in ('soft','bubble','arcade','retro','chime','laser','none'));
create table public.sound_packs (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 2 and 40),
  url text not null check (url ~ '^https://' and char_length(url)<500),
  enabled boolean not null default true
);
alter table public.sound_packs enable row level security;
create policy sound_packs_read on public.sound_packs for select to authenticated using (public.is_approved() and (enabled or public.is_admin()));
create policy sound_packs_insert on public.sound_packs for insert to authenticated with check (public.is_admin());
create policy sound_packs_update on public.sound_packs for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy sound_packs_delete on public.sound_packs for delete to authenticated using (public.is_admin());

create table public.xp_events (
  event_key text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  points integer not null,
  created_at timestamptz not null default now()
);
create index xp_daily on public.xp_events(user_id,created_at desc);
alter table public.xp_events enable row level security;
create table public.user_achievements (
  user_id uuid not null references public.profiles(id) on delete cascade,
  badge text not null,
  unlocked_at timestamptz not null default now(),
  primary key(user_id,badge)
);
alter table public.user_achievements enable row level security;
create policy achievements_read on public.user_achievements for select to authenticated using (public.is_approved());

create or replace function public.award_xp(p_user uuid,p_kind text,p_key text,p_points integer)
returns void language plpgsql security definer set search_path = '' as $$
declare earned integer; new_xp integer;
begin
  if p_points<1 or p_points>5 then return; end if;
  if not (select xp_enabled from public.app_settings where id=1) then return; end if;
  if p_kind in ('message','reaction') and exists(select 1 from public.xp_events
    where user_id=p_user and kind=p_kind and created_at>now()-interval '2 minutes') then return; end if;
  select coalesce(sum(points),0) into earned from public.xp_events
    where user_id=p_user and created_at>=date_trunc('day',now() at time zone 'Asia/Riyadh') at time zone 'Asia/Riyadh';
  if earned>=40 then return; end if;
  insert into public.xp_events(event_key,user_id,kind,points) values(p_key,p_user,p_kind,least(p_points,40-earned))
    on conflict do nothing;
  if not found then return; end if;
  update public.profiles set xp=xp+least(p_points,40-earned) where id=p_user returning xp into new_xp;
  if new_xp>=20 then insert into public.user_achievements(user_id,badge) values(p_user,'Getting started') on conflict do nothing; end if;
  if new_xp>=100 then insert into public.user_achievements(user_id,badge) values(p_user,'Office regular') on conflict do nothing; end if;
  if new_xp>=500 then insert into public.user_achievements(user_id,badge) values(p_user,'RZYN legend') on conflict do nothing; end if;
  if p_kind='poll' then insert into public.user_achievements(user_id,badge) values(p_user,'Poll explorer') on conflict do nothing; end if;
end $$;
revoke all on function public.award_xp(uuid,text,text,integer) from public,anon,authenticated;
create or replace function public.xp_after_message() returns trigger language plpgsql security definer set search_path = '' as $$
begin perform public.award_xp(new.author_id,'message','m:'||new.id,2); return new; end $$;
create trigger xp_message after insert on public.messages for each row execute function public.xp_after_message();
create or replace function public.xp_after_reaction() returns trigger language plpgsql security definer set search_path = '' as $$
begin perform public.award_xp(new.user_id,'reaction','r:'||new.message_id||':'||new.user_id||':'||new.emoji,1); return new; end $$;
create trigger xp_reaction after insert on public.message_reactions for each row execute function public.xp_after_reaction();
create or replace function public.xp_after_poll() returns trigger language plpgsql security definer set search_path = '' as $$
begin perform public.award_xp(new.user_id,'poll','p:'||new.poll_id||':'||new.user_id,4); return new; end $$;
create trigger xp_poll after insert on public.poll_votes for each row execute function public.xp_after_poll();

create or replace function public.set_my_birthday(p_month integer,p_day integer) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  if (p_month is null and p_day is not null) or (p_day is null and p_month is not null) then raise exception 'Month and day must both be set'; end if;
  if p_month is not null and (p_month not between 1 and 12 or p_day not between 1 and 31 or
    (p_month=2 and p_day>29) or (p_month in (4,6,9,11) and p_day>30)) then
    raise exception 'Invalid birthday';
  end if;
  update public.profiles set birthday_month=p_month,birthday_day=p_day where id=(select auth.uid());
end $$;
grant execute on function public.set_my_birthday(integer,integer) to authenticated;

create table public.admin_audit (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  target text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_recent on public.admin_audit(created_at desc);
alter table public.admin_audit enable row level security;
create policy audit_admin_read on public.admin_audit for select to authenticated using (public.is_admin());
create or replace function public.audit_admin_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() then
    insert into public.admin_audit(actor_id,action,target,details)
    values((select auth.uid()),TG_TABLE_NAME||'_'||lower(TG_OP),
      coalesce((case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id',
               (case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'room_id',''),
      jsonb_build_object('row',case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end));
  end if;
  if TG_OP='DELETE' then return old; end if;
  return new;
end $$;
create trigger audit_profiles after update on public.profiles for each row
when (old.name is distinct from new.name or old.username is distinct from new.username or old.status is distinct from new.status or old.role is distinct from new.role)
execute function public.audit_admin_change();
create trigger audit_rooms after insert or update or delete on public.rooms for each row execute function public.audit_admin_change();
create trigger audit_room_members after insert or update or delete on public.room_members for each row execute function public.audit_admin_change();
create trigger audit_stickers after insert or update or delete on public.stickers for each row execute function public.audit_admin_change();
create trigger audit_sound_packs after insert or update or delete on public.sound_packs for each row execute function public.audit_admin_change();
create trigger audit_settings after update on public.app_settings for each row execute function public.audit_admin_change();
create or replace function public.audit_content_delete() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if public.is_admin() then
    insert into public.admin_audit(actor_id,action,target,details)
      values((select auth.uid()),TG_TABLE_NAME||'_delete',old.id::text,
        jsonb_build_object('room_id',to_jsonb(old)->>'room_id'));
  end if;
  return old;
end $$;
create trigger audit_message_delete after delete on public.messages for each row execute function public.audit_content_delete();
create trigger audit_vent_delete after delete on public.vent_posts for each row execute function public.audit_content_delete();
create trigger audit_poll_delete after delete on public.polls for each row execute function public.audit_content_delete();
create trigger audit_quote_delete after delete on public.quote_nominations for each row execute function public.audit_content_delete();
create trigger audit_fame_delete after delete on public.fame_entries for each row execute function public.audit_content_delete();

create or replace function public.review_vent_identity(p_id bigint,p_reason text)
returns table(author_id uuid,member_code text,name text,username text)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'Admin required'; end if;
  if char_length(trim(p_reason)) not between 12 and 500 then raise exception 'A specific reason is required'; end if;
  if not exists(select 1 from private.vent_identity where post_id=p_id) then raise exception 'Post unavailable'; end if;
  insert into private.identity_access_log(post_id,admin_id,reason) values(p_id,(select auth.uid()),trim(p_reason));
  insert into public.admin_audit(actor_id,action,target,details)
    values((select auth.uid()),'vent_identity_review',p_id::text,jsonb_build_object('reason',trim(p_reason)));
  return query select p.id,p.member_code,p.name,p.username from private.vent_identity v
  join public.profiles p on p.id=v.author_id where v.post_id=p_id;
end $$;

alter table public.global_events drop constraint if exists global_events_kind_check;
alter table public.global_events add constraint global_events_kind_check
  check (kind in ('confetti','balloons','disco','ducks','nothing','laser','emoji_rain','shake','countdown','matrix'));
create or replace function public.press_button(p_kind text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare selected text; cooldown integer; enabled boolean;
begin
  if not public.is_approved() then raise exception 'Account not approved'; end if;
  perform pg_catalog.pg_advisory_xact_lock(9211001);
  select button_cooldown_minutes,button_enabled into cooldown,enabled from public.app_settings where id=1;
  if cooldown is null or (not enabled and not public.is_admin()) then raise exception 'The button is taking a break'; end if;
  if not public.is_admin() and exists(select 1 from public.global_events
    where created_at>now()-make_interval(mins=>cooldown)) then raise exception 'The button is cooling down'; end if;
  if p_kind is not null and public.is_admin() and
    p_kind in ('confetti','balloons','disco','ducks','nothing','laser','emoji_rain','shake','countdown','matrix')
    then selected:=p_kind;
  else selected:=(array['confetti','balloons','disco','ducks','nothing','laser','emoji_rain','shake','countdown','matrix'])[1+floor(random()*10)::int]; end if;
  insert into public.global_events(actor_id,kind) values((select auth.uid()),selected);
  insert into public.admin_audit(actor_id,action,target) values((select auth.uid()),'global_event',selected);
  return selected;
end $$;

-- Realtime payloads contain only ordinary chat data, never the private Vent mapping.
alter publication supabase_realtime add table public.message_reactions,public.polls,public.poll_votes,
  public.quote_nominations,public.quote_votes,public.stickers,public.sound_packs,public.user_achievements,public.room_members,public.fame_entries;

-- Presence is office-wide; typing uses a separate private channel per room.
create policy rzyn_private_receive on realtime.messages for select to authenticated using (
  (topic='rzyn-office' and extension='presence' and public.is_approved()) or
  (extension='broadcast' and topic ~ '^rzyn-room:[0-9]+$' and
    public.can_read_room(split_part(topic,':',2)::bigint))
);
create policy rzyn_private_send on realtime.messages for insert to authenticated with check (
  (topic='rzyn-office' and extension='presence' and public.is_approved()) or
  (extension='broadcast' and topic ~ '^rzyn-room:[0-9]+$' and
    public.can_post_room(split_part(topic,':',2)::bigint))
);

-- Service-role-only Web Push state. RLS prevents browser access even with the publishable key.
create table public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);
create index push_by_user on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon,authenticated;
create table public.push_dispatches (
  message_id bigint primary key references public.messages(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.push_dispatches enable row level security;
revoke all on public.push_dispatches from anon,authenticated;

create or replace function public.cleanup_rzyn() returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.messages where saved_at is null and expires_at<=now();
  delete from public.vent_posts where expires_at<=now();
  delete from public.polls where expires_at<=now();
  delete from public.global_events where created_at<now()-interval '7 days';
  delete from public.xp_events where created_at<now()-interval '2 days';
  delete from public.quote_nominations where quote_day<(now() at time zone 'Asia/Riyadh')::date-30;
  delete from public.fame_entries where featured_at<now()-interval '7 days';
  delete from public.push_dispatches where created_at<now()-interval '7 days';
  delete from public.admin_audit where created_at<now()-interval '180 days';
end $$;
revoke all on function public.cleanup_rzyn() from public,anon,authenticated;
