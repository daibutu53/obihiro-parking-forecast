-- 到着便・出発便の時刻表を取り込む（cron.sql のあとに SQL Editor で1回実行する。再実行しても壊れない）
-- データ元: https://www.hokkaido-airports.com/api/v1/obihiro/static/schedule/domestic.json（31日分）
-- 1時間に1回、obp_tick() が他の暦と一緒に取りにいく

create table if not exists obp_flights (
  day date not null,
  da text not null check (da in ('A','D')),   -- A=到着 D=出発
  flight text not null,                       -- 運航会社の便名（例 ADO61 / JAL573）
  airline text not null,                      -- ADO / JAL / ANA など
  codeshare text,                             -- 共同運航の便名（例 ANA4761）
  dep_time text,
  arr_time text,
  dep_airport text,
  arr_airport text,
  primary key (day, da, flight)
);
alter table obp_flights enable row level security;
drop policy if exists obp_flights_read on obp_flights;
create policy obp_flights_read on obp_flights for select to anon using (true);

alter table obp_pending drop constraint if exists obp_pending_kind_check;
alter table obp_pending add constraint obp_pending_kind_check
  check (kind in ('parking','busy','holiday','schedule'));

create or replace function obp_store_schedule(j jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if j->>'status' <> 'success' then return; end if;
  delete from obp_flights where day >= (now() at time zone 'Asia/Tokyo')::date;
  insert into obp_flights (day, da, flight, airline, codeshare, dep_time, arr_time, dep_airport, arr_airport)
  select d::date, it->>'DA', op->>'Flight', op->>'Airline_3Cd',
         (select string_agg(c->>'Flight', ' ') from jsonb_array_elements(it->'Airline') c
           where (c->>'SharingfltDiv')::int <> 0),
         it->>'DepartureTime', it->>'ArrivalTime', it->>'DepartureAreaCode', it->>'ArrivalAreaCode'
  from jsonb_array_elements(j->'items') it
  cross join lateral (
    select c from jsonb_array_elements(it->'Airline') c where (c->>'SharingfltDiv')::int = 0 limit 1
  ) o(op)
  cross join lateral jsonb_array_elements_text(it->'ActiveDate') d
  on conflict (day, da, flight) do update set
    airline = excluded.airline, codeshare = excluded.codeshare,
    dep_time = excluded.dep_time, arr_time = excluded.arr_time,
    dep_airport = excluded.dep_airport, arr_airport = excluded.arr_airport;
end $$;
revoke all on function obp_store_schedule(jsonb) from public, anon, authenticated;

create or replace function obp_process()
returns void
language plpgsql
security definer
set search_path = public, net
as $$
declare
  p record;
  j jsonb;
  today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  for p in
    select q.request_id, q.kind, r.created, r.status_code, r.content
    from obp_pending q
    join net._http_response r on r.id = q.request_id
  loop
    begin
      if p.status_code = 200 then
        j := p.content::jsonb;

        if p.kind = 'parking' and j->>'status' = 'success' then
          insert into obp_parking_log (fetched_at, source_updated, lot, capacity, status, text_small, text_large)
          select p.created,
                 (j->>'updated')::timestamp at time zone 'Asia/Tokyo',
                 i->'name'->>'ja', i->>'capacity', i->>'status',
                 nullif(i->>'textSmall',''), nullif(i->>'textLarge','')
          from jsonb_array_elements(j->'items'->'OBO') i
          where i->>'status' in ('full','crowded','available','suspended');

        elsif p.kind = 'holiday' then
          insert into obp_calendar (day, kind, label)
          select h.key::date, 'holiday', h.value from jsonb_each_text(j) h
          on conflict (day) do update set label = excluded.label
            where obp_calendar.kind <> 'busy';

        elsif p.kind = 'busy' then
          delete from obp_calendar where kind = 'busy' and day >= today;
          insert into obp_calendar (day, kind, label)
          select distinct d::date, 'busy', '混雑予想日'
          from jsonb_array_elements(j) b,
               generate_series((b->>'start')::date, (b->>'end')::date, interval '1 day') d
          on conflict (day) do update set kind = 'busy', label = excluded.label;

        elsif p.kind = 'schedule' then
          perform obp_store_schedule(j);
        end if;
      end if;
    exception when others then
      raise warning 'obp_process % %: %', p.kind, p.request_id, sqlerrm;
    end;
    delete from obp_pending where request_id = p.request_id;
  end loop;

  delete from obp_pending where sent_at < now() - interval '10 minutes';
end $$;

create or replace function obp_tick()
returns void
language plpgsql
security definer
set search_path = public, net
as $$
declare
  h jsonb := '{"User-Agent": "obihiro-parking-forecast/1.0"}';
  base text := 'https://www.hokkaido-airports.com';
begin
  perform obp_process();

  insert into obp_pending (request_id, kind)
  values (net.http_get(base || '/api/v2/obihiro/static/parking.json', headers => h, timeout_milliseconds => 20000), 'parking');

  -- 暦と時刻表は1時間に1回で足りる
  if extract(minute from now()) < 5 then
    insert into obp_pending (request_id, kind) values
      (net.http_get(base || '/api/v1/common/static/holiday.json', headers => h, timeout_milliseconds => 20000), 'holiday'),
      (net.http_get(base || '/ja/obihiro/access/parking/json/busy.json', headers => h, timeout_milliseconds => 20000), 'busy'),
      (net.http_get(base || '/api/v1/obihiro/static/schedule/domestic.json', headers => h, timeout_milliseconds => 20000), 'schedule');
  end if;
end $$;

revoke all on function obp_process() from public, anon, authenticated;
revoke all on function obp_tick() from public, anon, authenticated;
