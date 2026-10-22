-- =====================================================================
-- GE Speed-to-Lead Revenue Engine â€” Supabase schema
-- Run once: Supabase â†’ SQL Editor â†’ paste this whole file â†’ Run.
-- Safe to re-run (tables use IF NOT EXISTS, functions use OR REPLACE).
--
-- Why the logic lives here: every "never twice" and "cancel the old
-- reminders" rule is enforced inside ONE database transaction, so three
-- copies of the same event arriving at the same second cannot race.
-- n8n does the talking (AI, Gmail, GHL); Postgres keeps the score.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables

create table if not exists ge_settings (
  key   text primary key,
  value text not null
);

-- GHL pipeline + stage ids, filled by scripts/setup-ghl.ps1
create table if not exists ge_ghl_stages (
  stage       text primary key,
  pipeline_id text not null,
  stage_id    text not null
);

create table if not exists ge_leads (
  id                 bigint generated always as identity primary key,
  email              text not null,
  email_norm         text not null unique,
  first_name         text,
  last_name          text,
  phone              text,
  company            text,
  website            text,
  company_size       text,
  monthly_budget     text,
  service            text,
  timeline           text,
  message            text,
  source             text not null check (source in ('meta','website','referral','direct')),
  source_detail      jsonb not null default '{}',
  opted_in_at        timestamptz not null default now(),
  first_reply_at     timestamptz,
  qualification      text check (qualification in ('Qualified','Not Qualified','Needs Review')),
  score              int check (score between 0 and 100),
  reason             text,
  qualified_by       text,
  stage              text not null default 'New Lead' check (stage in
                       ('New Lead','Needs Review','Qualified','Not Qualified','Booked',
                        'Rescheduled','Showed','No-Show','Cancelled')),
  ghl_contact_id     text,
  ghl_opportunity_id text,
  ghl_synced_stage   text,
  ghl_synced_at      timestamptz,
  automation_paused  boolean not null default false,
  paused_reason      text,
  paused_at          timestamptz,
  owner_token        uuid not null default gen_random_uuid(),
  is_sample          boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Every incoming event (form post, Meta lead, Cal.com webhook, email) by its unique key.
create table if not exists ge_events (
  event_key  text primary key,
  kind       text not null,
  lead_id    bigint references ge_leads(id) on delete cascade,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  times_seen int not null default 1,
  payload    jsonb
);

create table if not exists ge_bookings (
  uid              text primary key,
  lead_id          bigint not null references ge_leads(id) on delete cascade,
  start_at         timestamptz,
  end_at           timestamptz,
  tz               text,
  video_url        text,
  status           text not null check (status in ('booked','rescheduled','cancelled','showed','no_show')),
  rescheduled_from text,
  cancel_reason    text,
  attendance_token uuid not null default gen_random_uuid(),
  is_sample        boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- Every outgoing email. message_key is UNIQUE: that is the "nobody gets the same message twice" guarantee.
create table if not exists ge_messages (
  id                  bigint generated always as identity primary key,
  message_key         text not null unique,
  lead_id             bigint references ge_leads(id) on delete cascade,
  booking_uid         text,
  template            text not null,
  to_owner            boolean not null default false,
  context             jsonb not null default '{}',
  send_at             timestamptz not null default now(),
  status              text not null default 'pending' check (status in ('pending','sending','sent','cancelled','failed')),
  attempts            int not null default 0,
  claimed_at          timestamptz,
  sent_at             timestamptz,
  provider_message_id text,
  cancel_reason       text,
  last_error          text,
  created_at          timestamptz not null default now()
);
create index if not exists ge_messages_due on ge_messages (send_at) where status = 'pending';
create index if not exists ge_messages_lead on ge_messages (lead_id);

-- GHL calendar link-up (added when booking moved from Cal.com to the GHL calendar)
alter table ge_bookings add column if not exists ghl_appt_id    text;
alter table ge_bookings add column if not exists reschedule_url text;
alter table ge_bookings add column if not exists cancel_url     text;
create index if not exists ge_bookings_appt on ge_bookings (ghl_appt_id);

create table if not exists ge_ad_spend (
  month  date not null,
  source text not null check (source in ('meta','website','referral')),
  spend  numeric(10,2) not null check (spend >= 0),
  what   text,
  primary key (month, source)
);

create table if not exists ge_errors (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  source    text,
  workflow  text,
  node      text,
  message   text,
  details   jsonb,
  resolved  boolean not null default false
);

-- Lock everything down: only the service_role key (held by n8n and the Vercel server) can read/write.
alter table ge_settings   enable row level security;
alter table ge_ghl_stages enable row level security;
alter table ge_leads      enable row level security;
alter table ge_events     enable row level security;
alter table ge_bookings   enable row level security;
alter table ge_messages   enable row level security;
alter table ge_ad_spend   enable row level security;
alter table ge_errors     enable row level security;

-- ---------------------------------------------------------------- helpers

create or replace function ge_setting(p_key text) returns text
language sql stable as $$ select value from ge_settings where key = p_key $$;

-- Everything n8n needs about a lead, including the GHL ids for its current stage.
create or replace function ge_lead_json(p_lead bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'lead_id', l.id, 'ref', 'L-' || l.id, 'email', l.email,
    'first_name', l.first_name, 'last_name', l.last_name, 'phone', l.phone,
    'company', l.company, 'website', l.website, 'company_size', l.company_size,
    'monthly_budget', l.monthly_budget, 'service', l.service, 'timeline', l.timeline,
    'message', l.message, 'source', l.source, 'stage', l.stage,
    'qualification', l.qualification, 'score', l.score, 'reason', l.reason,
    'automation_paused', l.automation_paused,
    'ghl_contact_id', l.ghl_contact_id, 'ghl_opportunity_id', l.ghl_opportunity_id,
    'ghl_pipeline_id', s.pipeline_id, 'ghl_stage_id', s.stage_id,
    'ghl_tags', to_jsonb(array_remove(array[
        'ge-lead',
        'ge-src-' || l.source,
        case when l.qualification is not null then 'ge-' || lower(replace(l.qualification, ' ', '-')) end,
        case when l.automation_paused then 'ge-human-takeover' end], null)),
    'opportunity_name', 'GE - ' || coalesce(nullif(l.company, ''), nullif(l.first_name, ''), l.email) || ' (L-' || l.id || ')',
    'ghl_source', case l.source when 'meta' then 'GE - Meta Ads' when 'website' then 'GE - Website'
                                when 'referral' then 'GE - Referral' else 'GE - Direct booking' end
  )
  from ge_leads l left join ge_ghl_stages s on s.stage = l.stage
  where l.id = p_lead
$$;

-- Queue an email. Returns the new id, or NULL if that exact message was already queued (= never twice).
create or replace function ge_queue(p_key text, p_lead bigint, p_template text,
  p_send_at timestamptz default now(), p_booking text default null,
  p_to_owner boolean default false, p_context jsonb default '{}')
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  insert into ge_messages (message_key, lead_id, template, send_at, booking_uid, to_owner, context)
  values (p_key, p_lead, p_template, p_send_at, p_booking, p_to_owner, coalesce(p_context, '{}'))
  on conflict (message_key) do nothing
  returning id into v_id;
  return v_id;
end $$;

create or replace function ge_cancel_pending(p_lead bigint, p_reason text,
  p_templates text[] default null, p_booking text default null)
returns int language plpgsql as $$
declare n int;
begin
  update ge_messages set status = 'cancelled', cancel_reason = p_reason
   where status = 'pending' and lead_id = p_lead
     and (p_templates is null or template = any (p_templates))
     and (p_booking is null or booking_uid = p_booking);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function ge_set_stage(p_lead bigint, p_stage text) returns void
language sql as $$ update ge_leads set stage = p_stage, updated_at = now() where id = p_lead $$;

-- Owner alert: logged in ge_errors AND emailed. The unique key means each problem alerts once.
create or replace function ge_alert(p_key text, p_lead bigint, p_title text, p_body text)
returns void language plpgsql as $$
begin
  if ge_queue(p_key, p_lead, 'owner_alert', now(), null, true,
              jsonb_build_object('title', p_title, 'body', p_body)) is not null then
    insert into ge_errors (source, message, details)
    values ('watchdog', p_title, jsonb_build_object('key', p_key, 'lead_id', p_lead, 'body', p_body));
  end if;
end $$;

-- ---------------------------------------------------------------- intake

-- Called by GE-01 for every incoming lead. Idempotent: a repeat of the same event (or the same
-- email from any source) returns the existing lead, so n8n simply continues where it left off.
create or replace function ge_intake(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_key      text := p->>'event_key';
  v_email    text := lower(trim(coalesce(p->>'email', '')));
  v_inserted boolean;
  v_lead     ge_leads;
  v_new      boolean := false;
  v_opt      timestamptz;
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'GE intake: invalid email "%"', p->>'email';
  end if;
  if coalesce(v_key, '') = '' then
    raise exception 'GE intake: missing event_key';
  end if;
  v_opt := least(coalesce(nullif(p->>'opted_in_at', '')::timestamptz, now()), now());

  insert into ge_events (event_key, kind, payload) values (v_key, 'intake', p)
  on conflict (event_key) do update
     set times_seen = ge_events.times_seen + 1, last_seen = now()
  returning (xmax = 0) into v_inserted;

  insert into ge_leads (email, email_norm, first_name, last_name, phone, company, website,
                        company_size, monthly_budget, service, timeline, message,
                        source, source_detail, opted_in_at)
  values (trim(p->>'email'), v_email, p->>'first_name', p->>'last_name', p->>'phone',
          p->>'company', p->>'website', p->>'company_size', p->>'monthly_budget',
          p->>'service', p->>'timeline', p->>'message',
          p->>'source', coalesce(p->'source_detail', '{}'), v_opt)
  on conflict (email_norm) do nothing
  returning * into v_lead;

  if found then
    v_new := true;
  else
    select * into v_lead from ge_leads where email_norm = v_email;
    -- First touch keeps the credit; later touches are remembered, not re-messaged.
    if v_inserted then
      update ge_leads
         set source_detail = jsonb_set(source_detail, '{other_touches}',
               coalesce(source_detail->'other_touches', '[]'::jsonb)
               || jsonb_build_array(jsonb_build_object('source', p->>'source', 'at', now()))),
             updated_at = now()
       where id = v_lead.id;
    end if;
  end if;

  update ge_events set lead_id = v_lead.id where event_key = v_key;

  return ge_lead_json(v_lead.id) || jsonb_build_object(
    'is_new_lead', v_new,
    'event_seen_before', not v_inserted,
    'needs_qualification', v_lead.qualification is null);
end $$;

-- Queues the right first reply (+ follow-ups) for a lead's qualification. Safe to call repeatedly.
create or replace function ge_queue_after_qualification(p_lead bigint) returns void
language plpgsql as $$
declare l ge_leads; k text;
begin
  select * into l from ge_leads where id = p_lead;
  k := 'L' || l.id || ':';
  if l.qualification = 'Qualified' then
    perform ge_queue(k || 'first_reply', l.id, 'qualified_booking_link');
    perform ge_queue(k || 'book_nudge_1', l.id, 'book_nudge_1', now() + interval '1 day');
    perform ge_queue(k || 'book_nudge_2', l.id, 'book_nudge_2', now() + interval '3 days');
  elsif l.qualification = 'Needs Review' then
    perform ge_queue(k || 'first_reply', l.id, 'needs_review_ack');
    perform ge_queue(k || 'owner_review', l.id, 'owner_needs_review', now(), null, true);
  elsif l.qualification = 'Not Qualified' then
    perform ge_queue(k || 'first_reply', l.id, 'not_qualified_reply');
  end if;
end $$;

-- Stores the AI verdict (first verdict wins) and queues the replies.
create or replace function ge_set_qualification(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_lead bigint := (p->>'lead_id')::bigint;
  v_q    text   := nullif(p->>'qualification', '');
begin
  if v_q is not null then
    if v_q not in ('Qualified', 'Not Qualified', 'Needs Review') then
      raise exception 'GE: bad qualification "%"', v_q;
    end if;
    update ge_leads
       set qualification = v_q,
           score = greatest(0, least(100, round(coalesce(nullif(p->>'score', '')::numeric, 50))::int)),
           reason = left(coalesce(p->>'reason', ''), 200),
           qualified_by = coalesce(p->>'qualified_by', 'ai'),
           stage = case v_q when 'Qualified' then 'Qualified'
                            when 'Not Qualified' then 'Not Qualified' else 'Needs Review' end,
           updated_at = now()
     where id = v_lead and qualification is null;
  end if;
  perform ge_queue_after_qualification(v_lead);
  return ge_lead_json(v_lead);
end $$;

create or replace function ge_ghl_synced(p jsonb) returns jsonb
language plpgsql as $$
begin
  update ge_leads
     set ghl_contact_id     = coalesce(nullif(p->>'contact_id', ''), ghl_contact_id),
         ghl_opportunity_id = coalesce(nullif(p->>'opportunity_id', ''), ghl_opportunity_id),
         ghl_synced_stage   = p->>'stage',
         ghl_synced_at      = now()
   where id = (p->>'lead_id')::bigint;
  return jsonb_build_object('ok', found);
end $$;

-- ---------------------------------------------------------------- bookings

create or replace function ge_queue_booking_msgs(p_lead bigint, p_uid text, p_confirm text)
returns void language plpgsql as $$
declare b ge_bookings; k text := 'L' || p_lead || ':';
begin
  select * into b from ge_bookings where uid = p_uid;
  perform ge_queue(k || p_confirm || ':' || p_uid, p_lead, p_confirm, now(), p_uid);
  if b.start_at - interval '24 hours' > now() + interval '30 minutes' then
    perform ge_queue(k || 'reminder_24h:' || p_uid, p_lead, 'reminder_24h', b.start_at - interval '24 hours', p_uid);
  end if;
  if b.start_at - interval '1 hour' > now() then
    perform ge_queue(k || 'reminder_1h:' || p_uid, p_lead, 'reminder_1h', b.start_at - interval '1 hour', p_uid);
  end if;
  perform ge_queue(k || 'attendance_check:' || p_uid, p_lead, 'attendance_check',
                   coalesce(b.end_at, b.start_at + interval '30 minutes') + interval '15 minutes', p_uid, true);
end $$;

-- The booking state machine. Used by Cal.com webhooks (GE-02) and owner buttons (GE-05).
-- event: created | rescheduled | cancelled | no_show | showed
create or replace function ge_booking_core(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_event text := p->>'event';
  v_uid   text := p->>'uid';
  v_old   text := nullif(p->>'old_uid', '');
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_name  text := trim(coalesce(p->>'name', ''));
  v_lead  bigint;
  v_b     ge_bookings;
  v_note  text := '';
  k       text;
begin
  if coalesce(v_uid, '') = '' then
    return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'event has no booking id');
  end if;

  -- 1. Which lead is this? metadata lead_id â†’ old booking â†’ this booking â†’ attendee email
  if coalesce(p->>'lead_id', '') ~ '^\d+$' then
    select id into v_lead from ge_leads where id = (p->>'lead_id')::bigint;
  end if;
  if v_lead is null and v_old is not null then select lead_id into v_lead from ge_bookings where uid = v_old; end if;
  if v_lead is null then select lead_id into v_lead from ge_bookings where uid = v_uid; end if;
  if v_lead is null and v_email <> '' then select id into v_lead from ge_leads where email_norm = v_email; end if;

  if v_lead is null then
    if v_event not in ('created', 'rescheduled') or v_email = '' then
      return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'booking ' || v_uid || ' is not linked to any lead');
    end if;
    -- Someone booked without opting in first: create them, flag for review.
    insert into ge_leads (email, email_norm, first_name, last_name, source, qualification, score,
                          reason, qualified_by, stage)
    values (v_email, v_email, split_part(v_name, ' ', 1),
            nullif(trim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), ''),
            'direct', 'Needs Review', 50, 'Booked a call without filling in a form first', 'rules', 'Needs Review')
    on conflict (email_norm) do update set updated_at = now()
    returning id into v_lead;
    perform ge_queue('L' || v_lead || ':owner_review', v_lead, 'owner_needs_review', now(), null, true);
    v_note := 'new lead created from a direct booking; ';
  end if;
  k := 'L' || v_lead || ':';

  if v_event = 'created' then
    select * into v_b from ge_bookings where uid = v_uid;
    if found then
      return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'ignored', true,
             'reason', 'booking already recorded as ' || v_b.status);
    end if;
    insert into ge_bookings (uid, lead_id, start_at, end_at, tz, video_url, status)
    values (v_uid, v_lead, (p->>'start_at')::timestamptz, (p->>'end_at')::timestamptz,
            p->>'tz', p->>'video_url', 'booked');
    perform ge_cancel_pending(v_lead, 'lead booked a call',
            array['book_nudge_1','book_nudge_2','noshow_1','noshow_2','noshow_3','cancel_followup']);
    perform ge_queue_booking_msgs(v_lead, v_uid, 'booking_confirm');
    perform ge_set_stage(v_lead, 'Booked');

  elsif v_event = 'rescheduled' then
    if v_old is not null then
      update ge_bookings set status = 'rescheduled', updated_at = now()
       where uid = v_old and status = 'booked';
      -- THE rule: a reschedule kills every reminder of the old time.
      perform ge_cancel_pending(v_lead, 'call was rescheduled', null, v_old);
    end if;
    insert into ge_bookings (uid, lead_id, start_at, end_at, tz, video_url, status, rescheduled_from)
    values (v_uid, v_lead, (p->>'start_at')::timestamptz, (p->>'end_at')::timestamptz,
            p->>'tz', p->>'video_url', 'booked', v_old)
    on conflict (uid) do update
       set start_at = excluded.start_at, end_at = excluded.end_at, status = 'booked',
           rescheduled_from = excluded.rescheduled_from, updated_at = now();
    perform ge_cancel_pending(v_lead, 'lead booked a call',
            array['book_nudge_1','book_nudge_2','noshow_1','noshow_2','noshow_3','cancel_followup']);
    perform ge_queue_booking_msgs(v_lead, v_uid, 'reschedule_confirm');
    perform ge_set_stage(v_lead, 'Rescheduled');

  elsif v_event = 'cancelled' then
    update ge_bookings set status = 'cancelled', cancel_reason = p->>'reason', updated_at = now()
     where uid = v_uid and status = 'booked'
    returning * into v_b;
    if not found then
      select * into v_b from ge_bookings where uid = v_uid;
      return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'ignored', true,
             'reason', 'booking is ' || coalesce(v_b.status, 'unknown') || ', nothing to cancel');
    end if;
    perform ge_cancel_pending(v_lead, 'call was cancelled', null, v_uid);
    if not exists (select 1 from ge_bookings where lead_id = v_lead and status = 'booked') then
      perform ge_set_stage(v_lead, 'Cancelled');
      perform ge_queue(k || 'cancelled_rebook:' || v_uid, v_lead, 'cancelled_rebook', now(), v_uid);
      perform ge_queue(k || 'cancel_followup:' || v_uid, v_lead, 'cancel_followup', now() + interval '2 days', v_uid);
    end if;

  elsif v_event = 'no_show' then
    update ge_bookings set status = 'no_show', updated_at = now()
     where uid = v_uid and status in ('booked', 'showed')
    returning * into v_b;
    if not found then
      select * into v_b from ge_bookings where uid = v_uid;
      return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'ignored', true,
             'reason', 'booking is ' || coalesce(v_b.status, 'unknown') || ', cannot mark no-show');
    end if;
    perform ge_cancel_pending(v_lead, 'marked as no-show', null, v_uid);
    if not exists (select 1 from ge_bookings where lead_id = v_lead and status = 'booked') then
      perform ge_set_stage(v_lead, 'No-Show');
      perform ge_queue(k || 'noshow_1:' || v_uid, v_lead, 'noshow_1', now() + interval '10 minutes', v_uid);
      perform ge_queue(k || 'noshow_2:' || v_uid, v_lead, 'noshow_2', now() + interval '1 day', v_uid);
      perform ge_queue(k || 'noshow_3:' || v_uid, v_lead, 'noshow_3', now() + interval '3 days', v_uid);
    end if;

  elsif v_event = 'showed' then
    update ge_bookings set status = 'showed', updated_at = now()
     where uid = v_uid and status in ('booked', 'no_show')
    returning * into v_b;
    if not found then
      select * into v_b from ge_bookings where uid = v_uid;
      return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'ignored', true,
             'reason', 'booking is ' || coalesce(v_b.status, 'unknown') || ', cannot mark showed');
    end if;
    perform ge_cancel_pending(v_lead, 'lead showed up', null, v_uid);
    perform ge_set_stage(v_lead, 'Showed');

  else
    return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'unhandled event ' || coalesce(v_event, '?'));
  end if;

  return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'ignored', false,
         'event', v_event, 'booking_uid', v_uid, 'note', v_note);
end $$;

-- Cal.com webhook entry point: checks the secret token, drops exact repeats, then runs the state machine.
create or replace function ge_booking_event(p jsonb) returns jsonb
language plpgsql as $$
declare v_key text; v_inserted boolean; v_seen int; v_res jsonb;
begin
  if coalesce(p->>'token', '') = '' or p->>'token' is distinct from ge_setting('calcom_token') then
    return jsonb_build_object('ok', false, 'ignored', true, 'reason', 'wrong or missing token');
  end if;
  v_key := 'cal:' || coalesce(p->>'event', '?') || ':' || coalesce(p->>'uid', '?') || ':' || coalesce(p->>'created_at', '');
  insert into ge_events (event_key, kind, payload) values (v_key, 'booking', p)
  on conflict (event_key) do update set times_seen = ge_events.times_seen + 1, last_seen = now()
  returning (xmax = 0), times_seen into v_inserted, v_seen;
  if not v_inserted then
    return jsonb_build_object('ok', true, 'ignored', true,
           'reason', 'duplicate delivery #' || v_seen || ' of ' || v_key);
  end if;
  v_res := ge_booking_core(p);
  update ge_events set lead_id = nullif(v_res->>'lead_id', '')::bigint where event_key = v_key;
  return v_res;
end $$;

-- ---------------------------------------------------------------- humans

-- Stops all lead-facing automation for one lead. Owner alerts still flow.
create or replace function ge_pause_lead(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_lead bigint;
  v_now  boolean := false;
  n      int := 0;
  v_reason text := coalesce(p->>'reason', 'paused');
begin
  if coalesce(p->>'lead_id', '') ~ '^\d+$' then
    select id into v_lead from ge_leads where id = (p->>'lead_id')::bigint;
  elsif coalesce(p->>'ref', '') ~* '^L-\d+$' then
    select id into v_lead from ge_leads where id = substr(p->>'ref', 3)::bigint;
  elsif coalesce(p->>'email', '') <> '' then
    select id into v_lead from ge_leads where email_norm = lower(trim(p->>'email'));
  end if;
  if v_lead is null then
    return jsonb_build_object('ok', true, 'found', false, 'ignored', true, 'reason', 'no matching lead');
  end if;

  update ge_leads set automation_paused = true, paused_reason = v_reason, paused_at = now(), updated_at = now()
   where id = v_lead and not automation_paused;
  v_now := found;

  update ge_messages set status = 'cancelled', cancel_reason = 'automation paused: ' || v_reason
   where lead_id = v_lead and status = 'pending' and not to_owner;
  get diagnostics n = row_count;

  if v_now then
    perform ge_queue('L' || v_lead || ':paused_notice', v_lead, 'owner_paused', now(), null, true,
                     jsonb_build_object('reason', v_reason, 'cancelled', n));
  end if;
  return ge_lead_json(v_lead) || jsonb_build_object('ok', true, 'found', true,
         'ignored', not v_now, 'paused_now', v_now, 'cancelled', n,
         'reason', case when v_now then v_reason else 'already paused' end);
end $$;

-- GE-04: an email arrived in the agency inbox (inbound) or a person sent one from it (outbound).
create or replace function ge_human_reply(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_dir     text := p->>'direction';
  v_from    text := lower(trim(coalesce(p->>'from_email', '')));
  v_to      text := lower(trim(coalesce(p->>'to_email', '')));
  v_subject text := coalesce(p->>'subject', '');
  v_ref     text := substring(v_subject from '(L-[0-9]+)');
  v_key     text := 'mail:' || coalesce(nullif(p->>'message_id', ''), md5(p::text));
  v_inserted boolean;
  v_res     jsonb;
begin
  insert into ge_events (event_key, kind, payload) values (v_key, 'email', p)
  on conflict (event_key) do update set times_seen = ge_events.times_seen + 1, last_seen = now()
  returning (xmax = 0) into v_inserted;
  if not v_inserted then
    return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'email already processed');
  end if;

  if v_dir = 'inbound' and v_from = lower(coalesce(ge_setting('agency_email'), '')) then
    return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'our own email');
  end if;
  if v_dir = 'outbound' then
    -- Sent by the automation itself? (same Gmail message id, or our subject format without "Re:")
    if exists (select 1 from ge_messages where provider_message_id = p->>'message_id') then
      return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'automated email');
    end if;
    if v_ref is not null and v_subject !~* '^\s*(re|fw|fwd)\s*:' then
      return jsonb_build_object('ok', true, 'ignored', true, 'reason', 'automated email (subject format)');
    end if;
  end if;

  v_res := ge_pause_lead(jsonb_build_object(
    'ref', v_ref,
    'email', case when v_ref is not null then null when v_dir = 'inbound' then v_from else v_to end,
    'reason', case when v_dir = 'inbound' then 'the lead replied by email'
                   else 'a team member replied by email' end));
  update ge_events set lead_id = nullif(v_res->>'lead_id', '')::bigint where event_key = v_key;
  return v_res;
end $$;

-- GE-05: owner clicked a button in an alert email (showed / no_show / takeover / approve / decline).
-- confirm=false only previews, so email link-scanners that open links can never change anything.
create or replace function ge_owner_action(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_action  text := p->>'action';
  v_token   text := coalesce(p->>'token', '');
  v_confirm boolean := coalesce((p->>'confirm')::boolean, false);
  b ge_bookings; l ge_leads; v_res jsonb; v_when text; v_who text;
begin
  if v_token !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'title', 'Link not valid', 'message', 'This link is broken or incomplete.');
  end if;

  if v_action in ('showed', 'no_show') then
    select * into b from ge_bookings where attendance_token = v_token::uuid;
    if not found then
      return jsonb_build_object('ok', false, 'title', 'Link not valid', 'message', 'No call matches this link.');
    end if;
    select * into l from ge_leads where id = b.lead_id;
    v_who  := trim(coalesce(l.first_name, '') || ' ' || coalesce(l.last_name, '')) || coalesce(' (' || nullif(l.company, '') || ')', '');
    v_when := to_char(b.start_at at time zone coalesce(b.tz, 'America/New_York'), 'Dy Mon DD, HH12:MI AM');
    if not v_confirm then
      return jsonb_build_object('ok', true, 'preview', true, 'action', v_action, 'token', v_token,
        'title', case v_action when 'showed' then 'Mark as SHOWED?' else 'Mark as NO-SHOW?' end,
        'message', v_who || ' â€” call on ' || v_when || '. Current status: ' || b.status || '.');
    end if;
    v_res := ge_booking_core(jsonb_build_object('event', v_action, 'uid', b.uid, 'lead_id', b.lead_id));
    return v_res || jsonb_build_object('title', case when (v_res->>'ignored')::boolean then 'Nothing changed' else 'Saved' end,
      'message', case when (v_res->>'ignored')::boolean then v_res->>'reason'
                      when v_action = 'showed' then v_who || ' marked as showed. Deal moved to Showed.'
                      else v_who || ' marked as no-show. Deal moved to No-Show and the re-book emails are scheduled.' end);
  end if;

  if v_action in ('takeover', 'approve', 'decline') then
    select * into l from ge_leads where owner_token = v_token::uuid;
    if not found then
      return jsonb_build_object('ok', false, 'title', 'Link not valid', 'message', 'No lead matches this link.');
    end if;
    v_who := trim(coalesce(l.first_name, '') || ' ' || coalesce(l.last_name, '')) || coalesce(' (' || nullif(l.company, '') || ')', '');
    if not v_confirm then
      return jsonb_build_object('ok', true, 'preview', true, 'action', v_action, 'token', v_token,
        'title', case v_action when 'takeover' then 'Stop automation for this lead?'
                               when 'approve' then 'Approve and send booking link?' else 'Decline politely?' end,
        'message', v_who || ' (L-' || l.id || '). Currently: ' || coalesce(l.qualification, 'not qualified yet')
                   || ', stage ' || l.stage || '.');
    end if;

    if v_action = 'takeover' then
      v_res := ge_pause_lead(jsonb_build_object('lead_id', l.id, 'reason', 'the owner took over'));
      return v_res || jsonb_build_object('title', 'Done', 'message',
        'Automation stopped for ' || v_who || '. ' || (v_res->>'cancelled') || ' scheduled email(s) cancelled. Reply to them personally.');
    end if;

    if l.qualification is distinct from 'Needs Review' then
      return ge_lead_json(l.id) || jsonb_build_object('ok', true, 'ignored', true, 'title', 'Nothing changed',
        'message', v_who || ' was already reviewed (now ' || coalesce(l.qualification, '?') || ').');
    end if;
    update ge_leads
       set qualification = case v_action when 'approve' then 'Qualified' else 'Not Qualified' end,
           stage         = case v_action when 'approve' then 'Qualified' else 'Not Qualified' end,
           qualified_by  = 'owner',
           reason        = left(coalesce(reason, '') || ' Â· ' || case v_action when 'approve' then 'approved' else 'declined' end || ' by owner', 200),
           updated_at    = now()
     where id = l.id;
    if v_action = 'approve' then
      perform ge_queue('L' || l.id || ':approved_link', l.id, 'approved_booking_link');
      perform ge_queue('L' || l.id || ':book_nudge_1', l.id, 'book_nudge_1', now() + interval '1 day');
      perform ge_queue('L' || l.id || ':book_nudge_2', l.id, 'book_nudge_2', now() + interval '3 days');
    else
      perform ge_queue('L' || l.id || ':declined', l.id, 'declined_reply');
    end if;
    return ge_lead_json(l.id) || jsonb_build_object('ok', true, 'ignored', false, 'title', 'Saved',
      'message', v_who || case v_action when 'approve' then ' approved. Booking link is on its way.'
                                         else ' declined. A polite email is on its way.' end);
  end if;

  return jsonb_build_object('ok', false, 'title', 'Unknown action', 'message', 'This link is not valid.');
end $$;

-- ---------------------------------------------------------------- sending

-- Why a due message must NOT be sent any more (NULL = fine to send). Last line of defence.
create or replace function ge_block_reason(p_id bigint) returns text
language plpgsql stable as $$
declare m ge_messages; l ge_leads; b ge_bookings;
begin
  select * into m from ge_messages where id = p_id;
  select * into l from ge_leads where id = m.lead_id;
  if m.booking_uid is not null then select * into b from ge_bookings where uid = m.booking_uid; end if;

  if not m.to_owner and l.automation_paused then
    return 'automation paused: ' || coalesce(l.paused_reason, '');
  end if;
  if m.template in ('booking_confirm','reschedule_confirm','reminder_24h','reminder_1h','attendance_check') then
    if b.status is distinct from 'booked' then return 'booking is now ' || coalesce(b.status, 'missing'); end if;
    if m.template in ('reminder_24h','reminder_1h') and b.start_at <= now() then return 'call time already passed'; end if;
  end if;
  if m.template like 'noshow\_%' then
    if b.status is distinct from 'no_show' then return 'no-show was cleared'; end if;
    if exists (select 1 from ge_bookings x where x.lead_id = l.id and x.status in ('booked','showed')
               and x.created_at > b.created_at) then return 'lead already rebooked'; end if;
  end if;
  if m.template in ('book_nudge_1','book_nudge_2') then
    if l.qualification is distinct from 'Qualified' then return 'lead is not qualified'; end if;
    if exists (select 1 from ge_bookings x where x.lead_id = l.id) then return 'lead already booked'; end if;
  end if;
  if m.template = 'cancel_followup'
     and exists (select 1 from ge_bookings x where x.lead_id = l.id and x.status = 'booked') then
    return 'lead already rebooked';
  end if;
  if m.template = 'owner_needs_review' and l.qualification is distinct from 'Needs Review' then
    return 'already reviewed';
  end if;
  return null;
end $$;

create or replace function ge_message_json(p_id bigint) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'id', m.id, 'message_key', m.message_key, 'template', m.template, 'to_owner', m.to_owner,
    'to_email', case when m.to_owner then ge_setting('owner_email') else l.email end,
    'context', m.context,
    'lead', case when l.id is null then null else
              ge_lead_json(l.id) || jsonb_build_object('owner_token', l.owner_token,
                'paused_reason', l.paused_reason, 'opted_in_at', l.opted_in_at) end,
    'booking', case when b.uid is null then null else jsonb_build_object(
                'uid', b.uid, 'start_at', b.start_at, 'end_at', b.end_at,
                'tz', coalesce(b.tz, 'America/New_York'), 'video_url', b.video_url,
                'attendance_token', b.attendance_token, 'status', b.status,
                'ghl_appt_id', b.ghl_appt_id, 'reschedule_url', b.reschedule_url, 'cancel_url', b.cancel_url) end,
    'settings', jsonb_build_object(
                'agency_name', ge_setting('agency_name'), 'sender_name', ge_setting('sender_name'),
                'booking_url', ge_setting('booking_url'), 'actions_url', ge_setting('actions_url'),
                'dashboard_url', ge_setting('dashboard_url')))
  from ge_messages m
  left join ge_leads l on l.id = m.lead_id
  left join ge_bookings b on b.uid = m.booking_uid
  where m.id = p_id
$$;

-- Finds silent failures and turns them into owner alerts (each problem alerts exactly once).
create or replace function ge_watchdog(p_ghl_failed boolean default false, p_ghl_error text default null)
returns void language plpgsql as $$
declare r record;
begin
  -- a) intake died before the AI verdict â†’ park as Needs Review so the lead still hears back
  for r in select id from ge_leads
            where qualification is null and not is_sample
              and opted_in_at < now() - interval '10 minutes' and opted_in_at > now() - interval '3 days' loop
    perform ge_set_qualification(jsonb_build_object('lead_id', r.id, 'qualification', 'Needs Review',
      'score', 50, 'reason', 'Automatic qualification did not finish - please review', 'qualified_by', 'watchdog'));
    perform ge_alert('watchdog:unqualified:L' || r.id, r.id, 'Lead L-' || r.id || ' was not qualified automatically',
      'The intake workflow stopped before the AI verdict. The lead was moved to Needs Review and sent a polite holding reply. Check the GE-01 executions in n8n.');
  end loop;

  -- b) no first reply within 5 minutes
  for r in select id from ge_leads
            where first_reply_at is null and not is_sample and not automation_paused
              and opted_in_at < now() - interval '5 minutes' and opted_in_at > now() - interval '3 days' loop
    perform ge_alert('watchdog:noreply:L' || r.id, r.id, 'Lead L-' || r.id || ' has no reply after 5 minutes',
      'This lead has not received its first email yet. Check GE-03 (sender) and the Gmail credential in n8n.');
  end loop;

  -- c) emails that failed 3 times (alerts about alerts are skipped to avoid loops)
  for r in select id, lead_id, template, last_error from ge_messages
            where status = 'failed' and template <> 'owner_alert' loop
    perform ge_alert('watchdog:failed:' || r.id, r.lead_id, 'An email could not be sent (' || r.template || ')',
      'Gave up after 3 tries. Last error: ' || coalesce(r.last_error, 'unknown'));
  end loop;

  -- d) (GHL deals are moved by GHL's own workflows, so there is no n8n->GHL sync to watch.)

  -- e) could not read the GHL stop tag (max one alert per hour)
  if p_ghl_failed then
    perform ge_alert('watchdog:ghlcheck:' || to_char(now(), 'YYYYMMDDHH24'), null, 'Could not read GoHighLevel tags',
      'The sender could not check for the ge-stop-automation tag: ' || coalesce(p_ghl_error, 'unknown error'));
  end if;
end $$;

-- GE-03 calls this every minute: apply GHL stop tags, rescue stuck sends, run the watchdog,
-- then claim due messages. FOR UPDATE SKIP LOCKED = two runs at once can never claim the same email.
create or replace function ge_sender_tick(p jsonb default '{}') returns jsonb
language plpgsql as $$
declare
  v_ids    text[];
  r        record;
  v_reason text;
  v_out    jsonb := '[]'::jsonb;
  v_paused int := 0;
begin
  select coalesce(array_agg(lower(trim(x))), '{}') into v_ids
    from jsonb_array_elements_text(coalesce(p->'stop_emails', '[]'::jsonb)) x;
  for r in select id from ge_leads where email_norm = any (v_ids) and not automation_paused and not is_sample loop
    perform ge_pause_lead(jsonb_build_object('lead_id', r.id, 'reason', 'the GHL tag ge-stop-automation was added'));
    v_paused := v_paused + 1;
  end loop;

  update ge_messages
     set status = case when attempts >= 3 then 'failed' else 'pending' end,
         last_error = left(coalesce(last_error || ' | ', '') || 'stuck in sending for 10+ minutes', 500)
   where status = 'sending' and claimed_at < now() - interval '10 minutes';

  perform ge_watchdog(coalesce((p->>'ghl_check_failed')::boolean, false), p->>'ghl_error');

  for r in select id from ge_messages
            where status = 'pending' and send_at <= now()
            order by send_at
            limit coalesce((p->>'limit')::int, 25)
            for update skip locked loop
    v_reason := ge_block_reason(r.id);
    if v_reason is not null then
      update ge_messages set status = 'cancelled', cancel_reason = v_reason where id = r.id;
    else
      update ge_messages set status = 'sending', attempts = attempts + 1, claimed_at = now() where id = r.id;
      v_out := v_out || jsonb_build_array(ge_message_json(r.id));
    end if;
  end loop;

  return jsonb_build_object('messages', v_out, 'count', jsonb_array_length(v_out), 'paused_by_tag', v_paused);
end $$;

create or replace function ge_mark_sent(p jsonb) returns jsonb
language plpgsql as $$
declare m ge_messages;
begin
  update ge_messages set status = 'sent', sent_at = now(), provider_message_id = nullif(p->>'provider_message_id', '')
   where id = (p->>'id')::bigint and status = 'sending'
  returning * into m;
  if found and not m.to_owner and m.lead_id is not null then
    update ge_leads set first_reply_at = now() where id = m.lead_id and first_reply_at is null;
  end if;
  return jsonb_build_object('ok', found);
end $$;

create or replace function ge_mark_failed(p jsonb) returns jsonb
language plpgsql as $$
declare m ge_messages;
begin
  update ge_messages
     set status     = case when attempts >= 3 then 'failed' else 'pending' end,
         send_at    = now() + attempts * interval '2 minutes',
         last_error = left(coalesce(p->>'error', 'unknown error'), 500)
   where id = (p->>'id')::bigint and status = 'sending'
  returning * into m;
  if found and m.status = 'failed' then
    insert into ge_errors (source, workflow, node, message, details)
    values ('sender', 'GE-03', 'Send email', 'Email failed 3 times: ' || m.template,
            jsonb_build_object('message_id', m.id, 'lead_id', m.lead_id, 'error', m.last_error));
  end if;
  return jsonb_build_object('ok', found, 'final', coalesce(m.status = 'failed', false));
end $$;

create or replace function ge_log_error(p jsonb) returns jsonb
language plpgsql as $$
declare v_id bigint;
begin
  insert into ge_errors (source, workflow, node, message, details)
  values (coalesce(p->>'source', 'n8n'), p->>'workflow', p->>'node', left(coalesce(p->>'message', '?'), 1000), p->'details')
  returning id into v_id;
  -- Errors raised outside n8n (e.g. the website form) also email the owner via the sender.
  if coalesce((p->>'alert')::boolean, false) then
    perform ge_queue('error:' || v_id, null, 'owner_alert', now(), null, true,
      jsonb_build_object('title', left(coalesce(p->>'message', 'Error'), 150),
                         'body', 'Source: ' || coalesce(p->>'source', '?') || '. Details: ' || coalesce((p->'details')::text, '-')));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ---------------------------------------------------------------- dashboard

-- Per-source numbers for a date range. Never blended: one row per source, no totals.
-- Spend is prorated by day, so a half-finished month only counts the money spent so far.
create or replace function ge_dashboard(p jsonb) returns jsonb
language sql stable as $$
with params as (
  select (p->>'from')::date as f, (p->>'to')::date as t,
         coalesce((p->>'include_sample')::boolean, true) as s
),
src as (select unnest(array['meta','website','referral']) as source),
cohort as (
  select l.*,
         exists (select 1 from ge_bookings b where b.lead_id = l.id) as booked,
         exists (select 1 from ge_bookings b where b.lead_id = l.id and b.status = 'showed') as showed,
         exists (select 1 from ge_bookings b where b.lead_id = l.id and b.status = 'no_show') as no_show,
         (extract(epoch from (l.first_reply_at - l.opted_in_at)) / 60.0)::float8 as reply_min
    from ge_leads l, params
   where (l.opted_in_at at time zone 'America/New_York')::date between params.f and params.t
     and (params.s or not l.is_sample)
),
agg as (
  select source,
         count(*) as leads,
         count(*) filter (where qualification = 'Qualified')     as qualified,
         count(*) filter (where qualification = 'Needs Review')  as needs_review,
         count(*) filter (where qualification = 'Not Qualified') as not_qualified,
         count(*) filter (where booked)                          as booked,
         count(*) filter (where showed)                          as showed,
         count(*) filter (where no_show and not showed)          as no_shows,
         percentile_cont(0.5) within group (order by reply_min) filter (where reply_min is not null) as median_reply_min,
         max(reply_min)                                          as slowest_reply_min,
         count(*) filter (where reply_min > 5)                   as replies_over_5_min,
         count(*) filter (where first_reply_at is null)          as not_replied
    from cohort group by source
),
spend as (
  select a.source,
         sum(a.spend
             * greatest(0, least((a.month + interval '1 month' - interval '1 day')::date, params.t)
                           - greatest(a.month, params.f) + 1)
             / extract(day from (a.month + interval '1 month' - interval '1 day'))) as spend
    from ge_ad_spend a, params
   group by a.source
)
select jsonb_build_object(
  'from', (select f from params), 'to', (select t from params),
  'include_sample', (select s from params),
  'sources', (select jsonb_agg(jsonb_build_object(
      'source', src.source,
      'leads', coalesce(agg.leads, 0), 'qualified', coalesce(agg.qualified, 0),
      'needs_review', coalesce(agg.needs_review, 0), 'not_qualified', coalesce(agg.not_qualified, 0),
      'booked', coalesce(agg.booked, 0), 'showed', coalesce(agg.showed, 0), 'no_shows', coalesce(agg.no_shows, 0),
      'median_reply_min', round(agg.median_reply_min::numeric, 1),
      'slowest_reply_min', round(agg.slowest_reply_min::numeric, 1),
      'replies_over_5_min', coalesce(agg.replies_over_5_min, 0),
      'not_replied', coalesce(agg.not_replied, 0),
      'spend', round(coalesce(spend.spend, 0)::numeric, 2)
    ) order by array_position(array['meta','website','referral'], src.source))
    from src left join agg on agg.source = src.source left join spend on spend.source = src.source),
  'health', jsonb_build_object(
      'errors_7d', (select count(*) from ge_errors where at > now() - interval '7 days' and not resolved),
      'last_error', (select message from ge_errors where not resolved order by at desc limit 1),
      'last_error_at', (select max(at) from ge_errors where not resolved),
      'emails_waiting', (select count(*) from ge_messages where status = 'pending' and send_at <= now() - interval '5 minutes'),
      'emails_failed', (select count(*) from ge_messages where status = 'failed'),
      'last_live_lead_at', (select max(opted_in_at) from ge_leads where not is_sample),
      'direct_bookings', (select count(*) from cohort where source = 'direct'))
)
$$;

-- ---------------------------------------------------------------- GHL calendar sync (read-only)

-- GHL contacts whose bookings are still "live" (upcoming, or recent enough to be marked showed/no-show).
create or replace function ge_ghl_watchlist(p jsonb default '{}') returns jsonb
language sql stable as $$
  select jsonb_build_object('contact_ids', coalesce(jsonb_agg(distinct l.ghl_contact_id), '[]'::jsonb))
    from ge_bookings b join ge_leads l on l.id = b.lead_id
   where not b.is_sample and l.ghl_contact_id is not null
     and b.status in ('booked', 'showed', 'no_show')
     and coalesce(b.start_at, now()) > now() - interval '2 days'
$$;

-- GE-02 reads a contact's appointments from GHL (read-only key) and sends them here.
-- We compare GHL's truth with what we know and run the booking state machine for each difference.
-- Polling the same state again changes nothing, so repeats are harmless by design.
-- p: {contact_id, email, ref, name, tz, reschedule_url, cancel_url, record_all,
--     events: [{id, status, start_at, end_at, deleted}]}
create or replace function ge_ghl_appt_sync(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_lead    bigint;
  v_email   text := lower(trim(coalesce(p->>'email', '')));
  v_ref     text := coalesce(p->>'ref', '');
  v_record  boolean := coalesce((p->>'record_all')::boolean, false);
  e         jsonb;
  v_id      text;
  v_status  text;
  v_start   timestamptz;
  v_end     timestamptz;
  v_uid     text;
  v_cur     ge_bookings;
  v_res     jsonb;
  v_base    jsonb;
  v_changes jsonb := '[]'::jsonb;
  v_key     text;
begin
  if v_ref ~* '^L-\d+$' then select id into v_lead from ge_leads where id = substr(v_ref, 3)::bigint; end if;
  if v_lead is null and coalesce(p->>'contact_id', '') <> '' then
    select id into v_lead from ge_leads where ghl_contact_id = p->>'contact_id' order by id limit 1;
  end if;
  if v_lead is null and v_email <> '' then select id into v_lead from ge_leads where email_norm = v_email; end if;

  for e in select x from jsonb_array_elements(coalesce(p->'events', '[]'::jsonb)) x
            order by (x->>'start_at') loop
    v_id     := e->>'id';
    v_status := lower(coalesce(e->>'status', ''));
    if coalesce((e->>'deleted')::boolean, false) then v_status := 'cancelled'; end if;
    v_start  := nullif(e->>'start_at', '')::timestamptz;
    v_end    := nullif(e->>'end_at', '')::timestamptz;
    continue when v_id is null or v_start is null;
    -- A reschedule keeps GHL's appointment id but changes the time, so our booking id includes the time.
    v_uid  := v_id || '@' || to_char(v_start at time zone 'UTC', 'YYYYMMDD"T"HH24MI');
    v_cur  := null;
    select * into v_cur from ge_bookings where ghl_appt_id = v_id order by created_at desc limit 1;
    v_base := jsonb_build_object('lead_id', v_lead, 'email', v_email, 'name', p->>'name',
                                 'start_at', v_start, 'end_at', v_end, 'tz', p->>'tz');
    v_res  := null;

    if v_status in ('confirmed', 'booked', 'new', 'pending') then
      if v_cur.uid is null then
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'created', 'uid', v_uid));
      elsif v_cur.uid <> v_uid and v_cur.status = 'booked' then
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'rescheduled', 'uid', v_uid, 'old_uid', v_cur.uid));
      end if;
    elsif v_status in ('cancelled', 'canceled', 'invalid') then
      if v_cur.status = 'booked' then
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'cancelled', 'uid', v_cur.uid, 'reason', 'cancelled in GHL'));
      end if;
    elsif v_status in ('showed', 'noshow', 'no_show', 'no-show') then
      if v_cur.uid is null then   -- an outcome for a booking we never saw: record the booking first
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'created', 'uid', v_uid));
        update ge_bookings set ghl_appt_id = v_id where uid = v_uid and ghl_appt_id is null;
        select * into v_cur from ge_bookings where uid = v_uid;
      end if;
      if v_status = 'showed' and v_cur.status in ('booked', 'no_show') then
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'showed', 'uid', v_cur.uid));
      elsif v_status <> 'showed' and v_cur.status in ('booked', 'showed') then
        v_res := ge_booking_core(v_base || jsonb_build_object('event', 'no_show', 'uid', v_cur.uid));
      end if;
    end if;

    if v_res is not null and nullif(v_res->>'lead_id', '') is not null then
      v_lead := (v_res->>'lead_id')::bigint;
    end if;
    update ge_bookings
       set ghl_appt_id    = coalesce(ghl_appt_id, v_id),
           reschedule_url = coalesce(nullif(p->>'reschedule_url', ''), reschedule_url),
           cancel_url     = coalesce(nullif(p->>'cancel_url', ''), cancel_url)
     where uid = v_uid;

    v_key := 'ghl:' || v_uid || ':' || v_status;
    if (v_res is not null and not coalesce((v_res->>'ignored')::boolean, false)) or v_record then
      insert into ge_events (event_key, kind, lead_id, payload) values (v_key, 'booking', v_lead, e)
      on conflict (event_key) do update set times_seen = ge_events.times_seen + 1, last_seen = now();
    end if;
    if v_res is not null and not coalesce((v_res->>'ignored')::boolean, false) then
      v_changes := v_changes || jsonb_build_array(jsonb_build_object(
        'event', v_res->>'event', 'lead_id', v_res->'lead_id', 'stage', v_res->>'stage', 'uid', v_uid));
    end if;
  end loop;

  if v_lead is not null and coalesce(p->>'contact_id', '') <> '' then
    update ge_leads set ghl_contact_id = p->>'contact_id'
     where id = v_lead and ghl_contact_id is distinct from p->>'contact_id';
  end if;

  return jsonb_build_object('ok', true, 'lead_id', v_lead, 'changed', jsonb_array_length(v_changes), 'changes', v_changes);
end $$;

-- Everything that happened to one lead - powers the Test Lab page (proof for the hard cases).
create or replace function ge_lead_timeline(p jsonb) returns jsonb
language sql stable as $$
  select case when l.id is null then jsonb_build_object('found', false) else
    ge_lead_json(l.id) || jsonb_build_object(
      'found', true, 'opted_in_at', l.opted_in_at, 'first_reply_at', l.first_reply_at,
      'minutes_to_first_reply', round((extract(epoch from (l.first_reply_at - l.opted_in_at)) / 60.0)::numeric, 2),
      'paused_reason', l.paused_reason, 'ghl_synced_stage', l.ghl_synced_stage,
      'booking_url', ge_setting('booking_url'),
      'events', (select coalesce(jsonb_agg(jsonb_build_object('key', e.event_key, 'kind', e.kind,
                   'times_seen', e.times_seen, 'first_seen', e.first_seen) order by e.first_seen), '[]'::jsonb)
                   from ge_events e where e.lead_id = l.id),
      'bookings', (select coalesce(jsonb_agg(jsonb_build_object('uid', b.uid, 'status', b.status, 'start_at', b.start_at,
                   'rescheduled_from', b.rescheduled_from, 'ghl_appt_id', b.ghl_appt_id) order by b.created_at), '[]'::jsonb)
                   from ge_bookings b where b.lead_id = l.id),
      'messages', (select coalesce(jsonb_agg(jsonb_build_object('template', m.template, 'to_owner', m.to_owner,
                   'status', m.status, 'send_at', m.send_at, 'sent_at', m.sent_at, 'cancel_reason', m.cancel_reason,
                   'booking_uid', m.booking_uid, 'attempts', m.attempts) order by m.send_at, m.id), '[]'::jsonb)
                   from ge_messages m where m.lead_id = l.id))
  end
  from (select 1) x
  left join ge_leads l on l.email_norm = lower(trim(coalesce(p->>'email', '')))
$$;

-- ---------------------------------------------------------------- permissions

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'ge\_%' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------- ad spend sheet
-- Realistic monthly spend for a small US B2B agency (made up). Edit in Table Editor â†’ ge_ad_spend.
insert into ge_ad_spend (month, source, spend, what) values
  ('2026-08-01', 'meta',     3200, 'Meta Lead Ads: B2B lookalike + retargeting'),
  ('2026-08-01', 'website',  1950, 'Google Search Ads $1,350 + SEO/content retainer $600'),
  ('2026-08-01', 'referral',  450, 'Partner referral fees ($150 per qualified intro) + client thank-you gifts'),
  ('2026-09-01', 'meta',     3400, 'Meta Lead Ads: B2B lookalike + retargeting'),
  ('2026-09-01', 'website',  1950, 'Google Search Ads $1,350 + SEO/content retainer $600'),
  ('2026-09-01', 'referral',  600, 'Partner referral fees ($150 per qualified intro) + client thank-you gifts'),
  ('2026-10-01', 'meta',     3600, 'Meta Lead Ads: B2B lookalike + retargeting (budget raised)'),
  ('2026-10-01', 'website',  2050, 'Google Search Ads $1,450 + SEO/content retainer $600'),
  ('2026-10-01', 'referral',  600, 'Partner referral fees ($150 per qualified intro) + client thank-you gifts'),
  ('2026-11-01', 'meta',     3600, 'Planned'),
  ('2026-11-01', 'website',  2050, 'Planned'),
  ('2026-11-01', 'referral',  600, 'Planned')
on conflict (month, source) do nothing;
