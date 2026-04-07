"""
LRB Strategy — Backtest Engine CLI

Usage:
  python engine.py --data ../data/ym.csv --tz ct
  python engine.py --data ../data/US30_M1.csv --tz utc --delay 15 --regime 500
  python engine.py --data ../data/ym.csv --tz ct --risk 1.0 --trace
"""
import argparse
import statistics
from collections import defaultdict

from config import SESSION, FILTERS, TRADE, RISK, ACCOUNT, TIMEZONE_PRESETS
from data_loader import load_csv, group_by_day, get_daily_closes
from filters import (
    range_filter, regime_filter, trend_filter,
    SweepDetector, get_ny_entry_start_min,
    ftmo_daily_guard, ftmo_max_dd_check,
)
from trade_manager import run_trade, calc_pnl


def run_backtest(bars, tz, overrides=None):
    sess  = {**SESSION}
    filt  = {**FILTERS}
    trade = {**TRADE}
    risk  = {**RISK}
    acct  = {**ACCOUNT}

    if tz in TIMEZONE_PRESETS:
        sess.update(TIMEZONE_PRESETS[tz])
    if overrides:
        for k, v in overrides.items():
            if k in sess:   sess[k]  = v
            elif k in filt: filt[k]  = v
            elif k in trade:trade[k] = v
            elif k in risk: risk[k]  = v

    day_map, sd = group_by_day(bars)
    dc = get_daily_closes(day_map, sd)

    day_ranges = {}
    for d in sd:
        lon = [b for b in day_map[d] if sess["london_start"] <= b["dt"].hour < sess["london_end"]]
        if len(lon) >= 10:
            day_ranges[d] = max(b["h"] for b in lon) - min(b["l"] for b in lon)

    eq = acct["balance"]; peak = eq; start = eq; max_dd = 0.0
    wins = losses = be = skipped = 0
    gw = gl = wp = lp = 0.0
    consec = mc = 0
    pnls = []; monthly = defaultdict(float)
    yearly = defaultdict(lambda: {"w":0,"l":0,"be":0,"pnl":0.0,"t":0})
    trades_log = []
    ny_start_min = get_ny_entry_start_min(sess)

    for di, date in enumerate(sd):
        if date.weekday() >= 5: continue
        db  = day_map[date]
        lon = [b for b in db if sess["london_start"] <= b["dt"].hour < sess["london_end"]]
        if len(lon) < 10: continue
        rh = max(b["h"] for b in lon); rl = min(b["l"] for b in lon); rng = rh - rl

        ok, _ = range_filter(rng, filt)
        if not ok: skipped += 1; continue
        ok, _ = regime_filter(date, sd, day_ranges, filt)
        if not ok: skipped += 1; continue
        direction, _ = trend_filter(date, sd, dc, filt)
        if direction == "FLAT": skipped += 1; continue
        ok, _ = ftmo_max_dd_check(peak, eq, start, risk["ftmo_max_dd"])
        if not ok: skipped += 1; continue

        ny = [b for b in db
              if b["dt"].hour * 60 + b["dt"].minute >= ny_start_min
              and b["dt"].hour < sess["ny_close_h"]]
        if len(ny) < 5: continue

        day_start_eq = eq
        det = SweepDetector(rh, rl, direction, filt["confirm_bars"])
        entry_bar = entry_dir = None
        for i, bar in enumerate(ny):
            result = det.update(i, bar) if filt["require_sweep"] else (
                ("BUY", bar) if bar["c"] > rh and direction != "SELL" else
                ("SELL", bar) if bar["c"] < rl and direction != "BUY" else None
            )
            if result:
                entry_dir, entry_bar = result; entry_idx = i; break

        if not entry_bar: continue

        tr  = run_trade(entry_bar, entry_dir, ny[entry_idx+1:], trade)
        pnl = calc_pnl(tr, eq, risk["risk_per_leg_pct"] * 2, trade["sl_pips"])

        ok, _ = ftmo_daily_guard(day_start_eq, eq, pnl, start, risk["ftmo_daily_guard"])
        if not ok: skipped += 1; continue

        eq += pnl; peak = max(peak, eq)
        dd = (peak - eq) / peak * 100; max_dd = max(max_dd, dd)
        pnls.append(pnl)
        mk = str(date)[:7]; yy = str(date.year)
        monthly[mk] += pnl
        out = tr.outcome
        yearly[yy][out[0]] += 1; yearly[yy]["pnl"] += pnl; yearly[yy]["t"] += 1

        if out=="win":  wins+=1;gw+=pnl;wp+=tr.exit_pips;consec=0
        elif out=="loss":losses+=1;gl+=abs(pnl);lp+=abs(tr.exit_pips);consec+=1;mc=max(mc,consec)
        else: be+=1;consec=0

        trades_log.append({"date":str(date),"dir":entry_dir,
            "time":entry_bar["dt"].strftime("%H:%M"),"range":round(rng),
            "pips":round(tr.exit_pips,1),"pnl":round(pnl,2),"outcome":out,
            "reason":tr.exit_reason,"equity":round(eq,2)})

    total = wins+losses+be
    wr = wins/total*100 if total else 0
    pf = gw/gl if gl>0 else 0
    sharpe = 0.0
    if len(pnls)>1:
        mu=statistics.mean(pnls); sig=statistics.stdev(pnls)
        sharpe = round(mu/sig*16,2) if sig>0 else 0

    return {"wr":round(wr,1),"pf":round(pf,2),"net":round(eq-start,2),
            "net_pct":round((eq-start)/start*100,1),"max_dd":round(max_dd,1),
            "sharpe":sharpe,"total":total,"wins":wins,"losses":losses,
            "be":be,"skipped":skipped,"max_consec":mc,
            "avg_win_pips":round(wp/wins if wins else 0,1),
            "avg_loss_pips":round(lp/losses if losses else 0,1),
            "monthly":dict(monthly),"yearly":{k:dict(v) for k,v in yearly.items()},
            "trades":trades_log,
            "all_years_positive":all(yearly[y]["pnl"]>0 for y in yearly) if yearly else False}


def print_results(r, account=10_000):
    print(f"\n{'='*55}")
    print(f"  WR={r['wr']}%  PF={r['pf']}  Net={r['net']:+.0f}$ ({r['net_pct']:+.1f}%)")
    print(f"  DD={r['max_dd']}%  Sharpe={r['sharpe']}  MC={r['max_consec']}")
    print(f"  Trades={r['total']} W={r['wins']} L={r['losses']} BE={r['be']} Skip={r['skipped']}")
    for yr in sorted(r["yearly"]):
        d=r["yearly"][yr]; t=d["t"]
        print(f"  {yr}: WR={d['w']/t*100:.0f}%  P&L={d['pnl']:+.0f}$  W={d['w']} L={d['l']} BE={d['be']}")
    print()
    for mk in sorted(r["monthly"]):
        v=r["monthly"][mk]; pct=v/account*100
        tag=" ★ FTMO" if pct>=7 else " ✓" if pct>=3 else " ✗" if pct<-2 else ""
        print(f"  {mk}: {v:+.0f}$ ({pct:+.1f}%)  {'█'*int(abs(v)/30)}{tag}")


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--data",required=True)
    p.add_argument("--tz",default=None)
    p.add_argument("--risk",type=float)
    p.add_argument("--delay",type=int)
    p.add_argument("--regime",type=int)
    p.add_argument("--trace",action="store_true")
    args=p.parse_args()

    bars,auto_tz,fmt=load_csv(args.data)
    tz=args.tz or auto_tz
    print(f"Loaded {len(bars):,} bars | {fmt} | TZ: {tz}")

    ov={}
    if args.risk:             ov["risk_per_leg_pct"]=args.risk
    if args.delay is not None:ov["ny_delay_min"]=args.delay
    if args.regime:           ov["regime_filter"]=args.regime

    r=run_backtest(bars,tz,ov)
    print_results(r)
    if args.trace:
        for t in r["trades"]:
            print(f"  {t['date']} {t['dir']:4} {t['time']}  {t['pips']:+6.1f}p  {t['outcome']:4}  {t['reason']}")
