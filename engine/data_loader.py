"""
LRB Strategy — Data Loader
Auto-detects CSV format and timezone.

Supported formats:
  backtestmarket.com  : no header, semicolons, DD/MM/YYYY;HH:MM;O;H;L;C;V  (CT)
  MT5 export          : <DATE>\t<TIME>\t<OPEN>\t<HIGH>\t<LOW>\t<CLOSE>...  (UTC)
  bluecapitaltrading  : TAB header, Time/Open/High/Low/Close/Volume         (UTC)
  TradingView / MT4   : CSV/TAB header, date+time columns                  (UTC)
"""
from datetime import datetime
from collections import defaultdict
from pathlib import Path
import re


def detect_format(first_line: str) -> str:
    if "<DATE>" in first_line and "<TIME>" in first_line:
        return "mt5"
    sep = "\t" if "\t" in first_line else ";" if ";" in first_line else ","
    first_col = first_line.split(sep)[0].strip()
    if re.match(r"^\d{1,2}/\d{1,2}/\d{4}$", first_col):
        return "backtestmarket"
    hdrs = first_line.lower()
    if "time" in hdrs and "open" in hdrs:
        return "bluecapital"
    if "date" in hdrs or "datetime" in hdrs:
        return "tradingview"
    return "unknown"


def parse_dt(raw: str) -> datetime | None:
    """Parse any datetime string into a naive UTC datetime."""
    raw = raw.strip()
    raw = re.sub(r"\s+(UTC|GMT|EST|EDT|CET|CEST)$", "", raw, flags=re.I)
    # m is m.groups() — a 0-indexed tuple: m[0]=first group, m[1]=second, etc.
    patterns = [
        (r"^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{2}:\d{2}(?::\d{2})?)",
         lambda m: f"{m[2]}-{m[1].zfill(2)}-{m[0].zfill(2)}T{m[3]}"),   # DD/MM/YYYY
        (r"^(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}:\d{2}(?::\d{2})?)",
         lambda m: f"{m[0]}-{m[1]}-{m[2]}T{m[3]}"),                      # YYYY.MM.DD (MT5)
        (r"^(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}:\d{2}(?::\d{2})?)",
         lambda m: f"{m[2]}-{m[1]}-{m[0]}T{m[3]}"),                      # DD.MM.YYYY
    ]
    for pattern, builder in patterns:
        m = re.match(pattern, raw)
        if m:
            iso = builder(m.groups())
            fmt = "%Y-%m-%dT%H:%M:%S" if iso.count(":") >= 2 else "%Y-%m-%dT%H:%M"
            try:
                return datetime.strptime(iso, fmt)
            except ValueError:
                continue
    raw = raw.replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def load_csv(path: str) -> tuple[list[dict], str, str]:
    """
    Load CSV. Returns (bars, timezone, format_description).
    bars: sorted list of {dt, o, h, l, c}
    """
    lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    lines = [l for l in lines if l.strip() and not l.startswith("#")]
    if len(lines) < 3:
        raise ValueError("File too short")

    fmt_key = detect_format(lines[0])
    sep = "\t" if "\t" in lines[0] else ";" if ";" in lines[0] else ","
    bars = []

    if fmt_key == "backtestmarket":
        for line in lines:
            c = line.strip().replace("\r", "").split(";")
            if len(c) < 6: continue
            dt = parse_dt(c[0] + " " + c[1])
            if not dt: continue
            try:
                bars.append({"dt": dt, "o": float(c[2]), "h": float(c[3]),
                             "l": float(c[4]), "c": float(c[5])})
            except ValueError: continue
        tz, fmt = "ct", "backtestmarket.com (DD/MM/YYYY;HH:MM, CT)"

    elif fmt_key == "mt5":
        for line in lines[1:]:
            c = line.strip().replace("\r", "").split("\t")
            if len(c) < 6: continue
            dt = parse_dt(c[0] + " " + c[1])
            if not dt: continue
            try:
                bars.append({"dt": dt, "o": float(c[2]), "h": float(c[3]),
                             "l": float(c[4]), "c": float(c[5])})
            except ValueError: continue
        tz, fmt = "utc", "MetaTrader 5 export (YYYY.MM.DD, UTC)"

    else:
        hdrs = lines[0].lower().replace("\r", "").split(sep)
        hdrs = [h.strip().strip("<>\"'") for h in hdrs]
        def find(*names):
            for n in names:
                for i, h in enumerate(hdrs):
                    if n in h: return i
            return -1
        i_date, i_time = find("date"), find("time")
        i_o, i_h, i_l, i_c = find("open"), find("high"), find("low"), find("close")
        if any(x < 0 for x in [i_o, i_h, i_l, i_c]):
            raise ValueError(f"Cannot find OHLC columns. Headers: {hdrs}")
        for line in lines[1:]:
            c = line.strip().replace("\r", "").split(sep)
            if len(c) < 5: continue
            if i_date >= 0 and i_time >= 0 and i_date != i_time:
                raw = c[i_date].strip() + " " + c[i_time].strip()
            elif i_time >= 0: raw = c[i_time].strip()
            elif i_date >= 0: raw = c[i_date].strip()
            else: continue
            dt = parse_dt(raw)
            if not dt: continue
            try:
                bars.append({"dt": dt, "o": float(c[i_o]), "h": float(c[i_h]),
                             "l": float(c[i_l]), "c": float(c[i_c])})
            except ValueError: continue
        tz, fmt = "utc", f"Standard headered ({fmt_key}, UTC)"

    if len(bars) < 10:
        raise ValueError(f"Only {len(bars)} bars parsed")
    bars.sort(key=lambda b: b["dt"])
    return bars, tz, fmt


def group_by_day(bars):
    day_map = defaultdict(list)
    for b in bars: day_map[b["dt"].date()].append(b)
    return dict(day_map), sorted(day_map.keys())

def get_daily_closes(day_map, sorted_dates):
    return {d: day_map[d][-1]["c"] for d in sorted_dates}
