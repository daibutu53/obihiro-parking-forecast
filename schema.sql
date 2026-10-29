-- とかち帯広空港 駐車場の混雑予測（hosomichi と同じDBに相乗り・obp_ 接頭辞）
-- Supabase の SQL Editor で丸ごと1回実行する。再実行しても壊れない。

-- 30分ごとの記録（1回の取得で駐車場の数だけ行が入る）
create table if not exists obp_parking_log (
  id bigserial primary key,
  fetched_at timestamptz not null default now(),
  source_updated timestamptz,
  lot text not null,
  capacity text,
  status text not null check (status in ('full','crowded','available','suspended')),
  text_small text,
  text_large text
);
create index if not exists obp_parking_log_lot_time on obp_parking_log (lot, fetched_at desc);

-- 空港が出している「混雑予想日」と祝日（収集スクリプトが毎回上書き）
create table if not exists obp_calendar (
  day date primary key,
  kind text not null check (kind in ('busy','holiday')),
  label text
);

-- 書き込み用の合言葉（GitHub Secrets と同じ値）。誰にも読めない
create table if not exists obp_ingest_token (token text primary key);

alter table obp_parking_log enable row level security;
alter table obp_calendar enable row level security;
alter table obp_ingest_token enable row level security;

drop policy if exists obp_log_read on obp_parking_log;
create policy obp_log_read on obp_parking_log for select to anon using (true);
drop policy if exists obp_cal_read on obp_calendar;
create policy obp_cal_read on obp_calendar for select to anon using (true);
-- obp_ingest_token にはポリシーを付けない（anon からは見えない）

-- 書き込みはこの関数だけ。合言葉が合ったときだけ入れる
create or replace function obp_ingest(p_token text, p_rows jsonb, p_calendar jsonb default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not exists (select 1 from obp_ingest_token where token = p_token) then
    raise exception 'bad token';
  end if;

  insert into obp_parking_log (source_updated, lot, capacity, status, text_small, text_large)
  select (r->>'source_updated')::timestamptz, r->>'lot', r->>'capacity', r->>'status',
         nullif(r->>'text_small',''), nullif(r->>'text_large','')
  from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;

  if p_calendar is not null and jsonb_array_length(p_calendar) > 0 then
    delete from obp_calendar where day >= (now() at time zone 'Asia/Tokyo')::date;
    insert into obp_calendar (day, kind, label)
    select (c->>'day')::date, c->>'kind', c->>'label'
    from jsonb_array_elements(p_calendar) c
    on conflict (day) do update set kind = excluded.kind, label = excluded.label;
  end if;

  return n;
end $$;

revoke all on function obp_ingest(text, jsonb, jsonb) from public;
grant execute on function obp_ingest(text, jsonb, jsonb) to anon;

-- 日の種類: busy（空港の混雑予想日）> holiday（土日祝）> weekday
create or replace view obp_samples as
select
  l.lot,
  l.status,
  l.fetched_at,
  (l.fetched_at at time zone 'Asia/Tokyo')::date as day,
  (extract(hour from l.fetched_at at time zone 'Asia/Tokyo') * 2
   + floor(extract(minute from l.fetched_at at time zone 'Asia/Tokyo') / 30))::int as slot,
  case
    when c.kind = 'busy' then 'busy'
    when c.kind = 'holiday' or extract(isodow from l.fetched_at at time zone 'Asia/Tokyo') >= 6 then 'holiday'
    else 'weekday'
  end as day_type
from obp_parking_log l
left join obp_calendar c on c.day = (l.fetched_at at time zone 'Asia/Tokyo')::date;

-- 予測の元データ: 駐車場 × 日の種類 × 30分枠 ごとの状態の割合
create or replace view obp_slot_stats as
select
  lot, day_type, slot,
  count(*) as samples,
  count(distinct day) as days,
  round(avg((status = 'full')::int)::numeric, 3) as p_full,
  round(avg((status in ('full','crowded'))::int)::numeric, 3) as p_crowded_or_full
from obp_samples
where status <> 'suspended'
group by lot, day_type, slot;

-- 最新の状態（駐車場ごと）
create or replace view obp_latest as
select distinct on (lot) lot, capacity, status, text_small, text_large, source_updated, fetched_at
from obp_parking_log
order by lot, fetched_at desc;

grant select on obp_samples, obp_slot_stats, obp_latest to anon;
