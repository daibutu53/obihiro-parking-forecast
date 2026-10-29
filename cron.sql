-- Supabase 自身が5分ごとに空港の満空情報を取りにいく（pg_cron + pg_net）
-- schema.sql のあとに SQL Editor で1回実行する。再実行しても壊れない。
-- ※ obp_process / obp_tick は flights.sql で上書きしている。こちらを後から再実行すると時刻表の取り込みが消えるので、そのときは flights.sql も続けて実行する
--
-- 流れ: 5分ごとに obp_tick() が動く
--   1. 前回送ったリクエストの応答（net._http_response）を読んで記録する
--   2. 次のリクエストを送る（応答は数秒後に届くので、次の回で読む）
-- 記録の時刻は応答が届いた時刻（created）を使うので、5分ずれることはない

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- 送ったリクエストの控え
create table if not exists obp_pending (
  request_id bigint primary key,
  kind text not null check (kind in ('parking','busy','holiday')),
  sent_at timestamptz not null default now()
);
alter table obp_pending enable row level security;

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
        end if;
      end if;
    exception when others then
      raise warning 'obp_process % %: %', p.kind, p.request_id, sqlerrm;
    end;
    delete from obp_pending where request_id = p.request_id;
  end loop;

  -- 応答が来ないまま10分たった控えは捨てる
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
begin
  perform obp_process();

  insert into obp_pending (request_id, kind)
  values (net.http_get('https://www.hokkaido-airports.com/api/v2/obihiro/static/parking.json', headers => h, timeout_milliseconds => 20000), 'parking');

  -- 暦は1時間に1回で足りる
  if extract(minute from now()) < 5 then
    insert into obp_pending (request_id, kind)
    values (net.http_get('https://www.hokkaido-airports.com/api/v1/common/static/holiday.json', headers => h, timeout_milliseconds => 20000), 'holiday');
    insert into obp_pending (request_id, kind)
    values (net.http_get('https://www.hokkaido-airports.com/ja/obihiro/access/parking/json/busy.json', headers => h, timeout_milliseconds => 20000), 'busy');
  end if;
end $$;

revoke all on function obp_process() from public, anon, authenticated;
revoke all on function obp_tick() from public, anon, authenticated;

-- 5分ごと（同じ名前で登録し直すと上書きされる）
select cron.schedule('obp-collect', '*/5 * * * *', $$select obp_tick()$$);
