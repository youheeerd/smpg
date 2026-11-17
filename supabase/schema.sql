-- SMPG database. Paste this whole file into the Supabase SQL editor and run it once.
-- It is safe to run again: nothing is dropped and existing rows are kept.
--
-- How access works
--   * Players have no account. Their personal invite code is their key.
--   * Nobody can read or write the tables directly from the website.
--     Players go through three functions: redeem_code, save_play, submit_request.
--   * Hosts sign in with a Supabase Auth account that is listed in public.hosts.
--     Only hosts can read plays, requests and codes, or create and revoke codes.

-- ---------- tables ----------
create table if not exists public.hosts (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.requests (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  email_key  text not null unique,
  record     jsonb not null,
  status     text not null default 'new' check (status in ('new','approved','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.invite_codes (
  code          text primary key,
  label         text,
  request_id    uuid references public.requests(id) on delete set null,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  first_used_at timestamptz,
  revoked_at    timestamptz
);

create table if not exists public.plays (
  code         text primary key references public.invite_codes(code) on delete cascade,
  status       text not null default 'in_progress' check (status in ('in_progress','complete')),
  name         text,
  record       jsonb not null,
  started_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  completed_at timestamptz
);

-- ---------- lock the tables down ----------
alter table public.hosts        enable row level security;
alter table public.requests     enable row level security;
alter table public.invite_codes enable row level security;
alter table public.plays        enable row level security;

revoke all on public.hosts, public.requests, public.invite_codes, public.plays from anon, authenticated;
grant select on public.requests, public.invite_codes, public.plays to authenticated;

create or replace function public.is_host()
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.hosts h where h.user_id = auth.uid()) $$;

drop policy if exists "hosts read requests" on public.requests;
create policy "hosts read requests" on public.requests for select to authenticated using (public.is_host());
drop policy if exists "hosts read codes" on public.invite_codes;
create policy "hosts read codes" on public.invite_codes for select to authenticated using (public.is_host());
drop policy if exists "hosts read plays" on public.plays;
create policy "hosts read plays" on public.plays for select to authenticated using (public.is_host());

-- ---------- player functions ----------
-- Check an invite code. Returns the member's saved game (to resume on any device)
-- and, for an approved request, the answers they already sent.
create or replace function public.redeem_code(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  c public.invite_codes;
begin
  if length(v_code) < 6 or length(v_code) > 16 then
    return jsonb_build_object('ok', false);
  end if;
  select * into c from public.invite_codes where code = v_code and revoked_at is null;
  if not found then
    perform pg_sleep(0.4);  -- slows down guessing
    return jsonb_build_object('ok', false);
  end if;
  update public.invite_codes set first_used_at = coalesce(first_used_at, now()) where code = v_code;
  return jsonb_build_object(
    'ok', true,
    'code', v_code,
    'label', c.label,
    'prefill', (select r.record from public.requests r where r.id = c.request_id),
    'play', (select p.record from public.plays p where p.code = v_code)
  );
end $$;

-- Save a member's game. Called as they play and again when they finish.
create or replace function public.save_play(p_code text, p_record jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_status text;
begin
  if not exists (select 1 from public.invite_codes where code = v_code and revoked_at is null) then
    return jsonb_build_object('ok', false, 'reason', 'code');
  end if;
  if p_record is null or jsonb_typeof(p_record) <> 'object' or octet_length(p_record::text) > 60000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  v_status := case when p_record->>'status' = 'complete' then 'complete' else 'in_progress' end;
  insert into public.plays (code, status, name, record, completed_at)
  values (v_code, v_status, left(p_record->>'name', 80), p_record, case when v_status = 'complete' then now() end)
  on conflict (code) do update set
    status = excluded.status,
    name = excluded.name,
    record = excluded.record,
    updated_at = now(),
    completed_at = case when excluded.status = 'complete' then coalesce(public.plays.completed_at, now()) else public.plays.completed_at end;
  return jsonb_build_object('ok', true);
end $$;

-- A request to play from someone without a code. One per email address.
-- Sending again replaces the earlier request until a host has decided on it.
create or replace function public.submit_request(p_record jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_email text := trim(coalesce(p_record->>'email', ''));
begin
  if p_record is null or jsonb_typeof(p_record) <> 'object' or octet_length(p_record::text) > 20000
     or length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid');
  end if;
  insert into public.requests (email, email_key, record)
  values (v_email, lower(v_email), p_record)
  on conflict (email_key) do update set
    email = excluded.email, record = excluded.record, updated_at = now()
    where public.requests.status = 'new';
  return jsonb_build_object('ok', true);
end $$;

-- ---------- host functions ----------
create or replace function public.host_whoami()
returns boolean
language sql stable security definer set search_path = public
as $$ select public.is_host() $$;

-- Create a personal invite code. With a request id it also approves that request,
-- and the member's request answers carry over when they enter the code.
create or replace function public.host_create_code(p_label text default null, p_request_id uuid default null)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- no 0/O, 1/I/L
  v_pos constant int[] := array[0,1,2,3,4,5,10,11];             -- fully random bytes of a v4 uuid
  v_bytes bytea;
  v_code text;
  i int;
begin
  if not public.is_host() then
    raise exception 'Only a host can create invite codes' using errcode = '42501';
  end if;
  if p_request_id is not null then
    if not exists (select 1 from public.requests where id = p_request_id) then
      raise exception 'Request not found' using errcode = 'P0002';
    end if;
    select code into v_code from public.invite_codes where request_id = p_request_id and revoked_at is null limit 1;
    if v_code is not null then
      update public.requests set status = 'approved', updated_at = now() where id = p_request_id;
      return v_code;
    end if;
  end if;
  loop
    v_bytes := uuid_send(gen_random_uuid());
    v_code := '';
    foreach i in array v_pos loop
      v_code := v_code || substr(v_alpha, 1 + get_byte(v_bytes, i) % 31, 1);
    end loop;
    begin
      insert into public.invite_codes (code, label, request_id, created_by)
      values (v_code, nullif(trim(left(coalesce(p_label, ''), 120)), ''), p_request_id, auth.uid());
      exit;
    exception when unique_violation then
      null;  -- try another code
    end;
  end loop;
  if p_request_id is not null then
    update public.requests set status = 'approved', updated_at = now() where id = p_request_id;
  end if;
  return v_code;
end $$;

create or replace function public.host_revoke_code(p_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_host() then
    raise exception 'Only a host can revoke invite codes' using errcode = '42501';
  end if;
  update public.invite_codes set revoked_at = now() where code = upper(trim(p_code)) and revoked_at is null;
  return found;
end $$;

create or replace function public.host_decline_request(p_id uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_host() then
    raise exception 'Only a host can decline requests' using errcode = '42501';
  end if;
  update public.requests set status = 'declined', updated_at = now() where id = p_id;
  return found;
end $$;

-- ---------- who may call what ----------
revoke all on function public.is_host(), public.redeem_code(text), public.save_play(text, jsonb), public.submit_request(jsonb),
  public.host_whoami(), public.host_create_code(text, uuid), public.host_revoke_code(text), public.host_decline_request(uuid)
  from public, anon, authenticated;
grant execute on function public.redeem_code(text), public.save_play(text, jsonb), public.submit_request(jsonb) to anon, authenticated;
grant execute on function public.is_host(), public.host_whoami(), public.host_create_code(text, uuid),
  public.host_revoke_code(text), public.host_decline_request(uuid) to authenticated;
