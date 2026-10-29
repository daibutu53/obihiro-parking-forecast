"""とかち帯広空港の満空情報を取得して Supabase に記録する（手動の予備。ふだんは Supabase の pg_cron が5分ごとに記録する）。

環境変数: SUPABASE_URL / SUPABASE_ANON_KEY / INGEST_TOKEN
標準ライブラリだけで動く。
"""
import json
import os
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone

SITE = "https://www.hokkaido-airports.com"
PARKING_URL = f"{SITE}/api/v2/obihiro/static/parking.json"
BUSY_URL = f"{SITE}/ja/obihiro/access/parking/json/busy.json"
HOLIDAY_URL = f"{SITE}/api/v1/common/static/holiday.json"
JST = timezone(timedelta(hours=9))


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "obihiro-parking-forecast/1.0"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def parking_rows():
    d = get_json(PARKING_URL)
    if d.get("status") != "success":
        raise RuntimeError(f"parking api status: {d.get('status')}")
    # "2026-10-29T13:46:28" は日本時間
    updated = datetime.fromisoformat(d["updated"]).replace(tzinfo=JST).isoformat()
    return [
        {
            "source_updated": updated,
            "lot": item["name"]["ja"],
            "capacity": item.get("capacity"),
            "status": item["status"],
            "text_small": item.get("textSmall", ""),
            "text_large": item.get("textLarge", ""),
        }
        for item in d["items"]["OBO"]
    ]


def calendar_rows():
    """空港の混雑予想日と祝日。取れなかったら None（既存の暦を残す）"""
    try:
        days = {}
        for k, label in get_json(HOLIDAY_URL).items():
            days[k] = {"day": k, "kind": "holiday", "label": label}
        for r in get_json(BUSY_URL):
            d, end = date.fromisoformat(r["start"]), date.fromisoformat(r["end"])
            while d <= end:
                days[d.isoformat()] = {"day": d.isoformat(), "kind": "busy", "label": "混雑予想日"}
                d += timedelta(days=1)
        return list(days.values())
    except Exception as e:
        print(f"calendar skipped: {e}", file=sys.stderr)
        return None


def ingest(rows, calendar):
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/rpc/obp_ingest"
    key = os.environ["SUPABASE_ANON_KEY"]
    body = json.dumps(
        {"p_token": os.environ["INGEST_TOKEN"], "p_rows": rows, "p_calendar": calendar}
    ).encode()
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def main():
    rows = parking_rows()
    calendar = calendar_rows()
    n = ingest(rows, calendar)
    print(f"inserted {n} rows:", ", ".join(f"{r['lot']}={r['status']}" for r in rows))
    if calendar:
        print(f"calendar {len(calendar)} days")


if __name__ == "__main__":
    main()
