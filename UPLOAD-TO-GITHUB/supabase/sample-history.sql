-- =====================================================================
-- GE Speed-to-Lead — SAMPLE history (made-up people, example.com emails)
-- Gives the dashboard ~2.5 months of realistic numbers to show.
-- Every row is flagged is_sample = true; the dashboard has a toggle to hide them,
-- and nothing here is ever emailed (no messages are queued for sample leads).
-- Re-running replaces the previous sample rows.
-- =====================================================================
do $$
declare
  fn  text[] := array['Avery','Jordan','Taylor','Morgan','Riley','Casey','Quinn','Harper','Rowan','Elliot',
                      'Dana','Skyler','Reese','Parker','Sydney','Blake','Cameron','Drew','Emerson','Finley'];
  lnm text[] := array['Whitlow','Brennan','Okafor','Lindqvist','Marchetti','Holloway','Castellano','Pruitt',
                      'Vance','Delacroix','Ashby','Kowalski','Nakamura','Fairbanks','Thornbury','Ellery'];
  co1 text[] := array['Northwind','Bluecrest','Ironleaf','Summit Ridge','Harborline','Copperfield','Brightwater',
                      'Granite Peak','Oakhaven','Silverline','Redstone','Clearpath','Westbrook','Pinecone'];
  co2 text[] := array['Logistics','Software','Manufacturing','IT Services','Staffing','Engineering','Supply Co',
                      'Analytics','Security','Consulting'];
  rq  text[] := array['US B2B SaaS, 40 staff, $5k+/mo budget, wants pipeline in 60 days',
                      'Manufacturer with sales team, clear budget and urgent timeline',
                      'IT services firm, 25 employees, budget fits, ready to start this quarter'];
  rr  text[] := array['Budget unclear and company size not given',
                      'Good fit industry but budget is $1k-3k',
                      'Enterprise (1000+) - different sales motion, needs a human look'];
  rn  text[] := array['Consumer business, not B2B',
                      'Budget under $1,000 per month',
                      'Job seeker, not a buyer',
                      'Solo freelancer, no sales team',
                      'Vendor pitching their own services'];
  src text; d date; i int; n int; k int := 0;
  q text; sc int; v_id bigint; opt timestamptz; mins numeric; st timestamptz; bstat text;
  p_q numeric; p_r numeric; p_book numeric; p_show numeric;
begin
  perform setseed(0.4242);
  delete from ge_leads where is_sample;   -- bookings/events cascade

  for d in select generate_series(date '2026-08-01', current_date - 1, interval '1 day')::date loop
    foreach src in array array['meta','website','referral'] loop
      n := case src
             when 'meta'    then floor(random() * 6)::int                      -- ~2.5 a day
             when 'website' then floor(random() * 3.3)::int                    -- ~1.2 a day
             else case when random() < 0.33 then 1 else 0 end                  -- ~10 a month
           end;
      -- qualified %, needs-review %, book % (of qualified), show % (of booked)
      p_q    := case src when 'meta' then 0.30 when 'website' then 0.45 else 0.75 end;
      p_r    := case src when 'meta' then 0.15 when 'website' then 0.15 else 0.10 end;
      p_book := case src when 'meta' then 0.50 when 'website' then 0.62 else 0.80 end;
      p_show := case src when 'meta' then 0.55 when 'website' then 0.72 else 0.88 end;

      for i in 1..n loop
        k := k + 1;
        if random() < p_q then q := 'Qualified'; sc := 70 + floor(random() * 26)::int;
        elsif random() < p_r / (1 - p_q) then q := 'Needs Review'; sc := 45 + floor(random() * 25)::int;
        else q := 'Not Qualified'; sc := 5 + floor(random() * 35)::int;
        end if;

        opt  := (d::timestamp + interval '7 hours' + random() * interval '14 hours') at time zone 'America/New_York';
        mins := case when random() < 0.04 then 6 + random() * 9 else 0.4 + random() * 2.4 end;

        insert into ge_leads (email, email_norm, first_name, last_name, company, company_size, monthly_budget,
                              service, timeline, source, source_detail, opted_in_at, first_reply_at,
                              qualification, score, reason, qualified_by, stage, is_sample,
                              ghl_synced_stage, created_at, updated_at)
        values ('sample.' || lpad(k::text, 4, '0') || '@example.com', 'sample.' || lpad(k::text, 4, '0') || '@example.com',
                fn[1 + floor(random() * array_length(fn, 1))::int], lnm[1 + floor(random() * array_length(lnm, 1))::int],
                co1[1 + floor(random() * array_length(co1, 1))::int] || ' ' || co2[1 + floor(random() * array_length(co2, 1))::int],
                (array['1-10','11-50','51-200','201-1000'])[1 + floor(random() * 4)::int],
                (array['Under $1,000','$1,000-$3,000','$3,000-$10,000','$10,000+'])[1 + floor(random() * 4)::int],
                (array['Lead generation','Paid ads','Outbound sales','Marketing automation'])[1 + floor(random() * 4)::int],
                (array['ASAP','Within 30 days','1-3 months','Just researching'])[1 + floor(random() * 4)::int],
                src, jsonb_build_object('sample', true), opt, opt + mins * interval '1 minute',
                q, sc,
                case q when 'Qualified' then rq[1 + floor(random() * 3)::int]
                       when 'Needs Review' then rr[1 + floor(random() * 3)::int]
                       else rn[1 + floor(random() * 5)::int] end,
                'ai', q, true, q, opt, opt)
        returning id into v_id;

        if q = 'Qualified' and random() < p_book then
          st := date_trunc('hour', opt + (1 + floor(random() * 6)) * interval '1 day') ;
          st := date_trunc('day', st) + (14 + floor(random() * 7)) * interval '1 hour';   -- 10am-4pm ET-ish
          bstat := case when st > now() then 'booked'
                        when random() < 0.05 then 'cancelled'
                        when random() < p_show then 'showed' else 'no_show' end;
          insert into ge_bookings (uid, lead_id, start_at, end_at, tz, status, is_sample, created_at)
          values ('sample-' || v_id, v_id, st, st + interval '30 minutes', 'America/New_York', bstat, true,
                  opt + interval '20 minutes');
          update ge_leads set stage = case bstat when 'booked' then 'Booked' when 'showed' then 'Showed'
                                                  when 'no_show' then 'No-Show' else 'Cancelled' end,
                              ghl_synced_stage = case bstat when 'booked' then 'Booked' when 'showed' then 'Showed'
                                                  when 'no_show' then 'No-Show' else 'Cancelled' end
           where id = v_id;
        end if;
      end loop;
    end loop;
  end loop;
end $$;

-- Quick check: leads per source in the sample
select source, count(*) leads,
       count(*) filter (where qualification = 'Qualified') qualified,
       count(*) filter (where stage in ('Booked','Showed','No-Show','Cancelled')) booked,
       count(*) filter (where stage = 'Showed') showed
  from ge_leads where is_sample group by source order by source;
