# -*- coding: utf-8 -*-
"""
3-stage cross-dataset optimisation (fast).
Stage 1: coarse sweep on YM 2yr subset (fast) -> top 50
Stage 2: validate top 50 on full YM 5yr -> top 15
Stage 3: validate top 15 on all 3 datasets -> final ranking
"""
import sys, os
sys.path.insert(0, '.')
from data_loader import load_csv
from engine import run_backtest

# Write to file to avoid Windows console encoding issues
out = open('sweep_out.txt', 'w', encoding='utf-8')

def p(s=''):
    print(s)   # console (may garble on Windows but won't crash)
    print(s, file=out)  # file always UTF-8
    out.flush()

p("Loading datasets...")
bars_mt5,  _, _ = load_csv('../US30_M1_MT5_JAN_APRIL_10.csv')
bars_ym20, _, _ = load_csv('../ym-1m_bk - 2020-today.csv')
bars_usa30,_, _ = load_csv('../USA30IDXUSD_M1 200000 bars.csv')

# YM 2yr subset (2023-2024) for fast stage-1 sweep
bars_ym_fast = [b for b in bars_ym20 if 2023 <= b['dt'].year <= 2024]
p(f"  MT5={len(bars_mt5):,}  YM_full={len(bars_ym20):,}  YM_fast={len(bars_ym_fast):,}  USA30={len(bars_usa30):,}")
p()

def is_ok(r):
    return r['total'] >= 5 and r['pf'] >= 1.3 and r['max_dd'] < 8 and r['net_pct'] > 0

def score_r(r, wt=1.0):
    if r['total'] < 5: return 0.0
    return r['net_pct'] * r['pf'] / max(r['max_dd'], 0.5) * wt

# ── Stage 1: coarse sweep on YM 2yr ──────────────────────────────────────
p("Stage 1: YM 2yr coarse sweep...")
stage1 = []
for regime in [300, 350, 400, 450, 500]:
    for delay in [10, 15, 20, 25]:
        for cp1 in [30, 40, 50]:
            for cp2 in [60, 80, 100]:
                if cp2 <= cp1: continue
                for cp4 in [200, 250, 300]:
                    for min_r in [80, 100, 120]:
                        ov = {'regime_filter': regime, 'ny_delay_min': delay,
                              'cp1_pips': cp1, 'cp2_pips': cp2,
                              'cp4_pips': cp4, 'min_range': min_r}
                        r = run_backtest(bars_ym_fast, 'ct', ov)
                        stage1.append((score_r(r), ov, r))

stage1.sort(key=lambda x: -x[0])
p(f"  {len(stage1)} combos. Top 5 on YM 2yr:")
for s, ov, r in stage1[:5]:
    p(f"    r={ov['regime_filter']} d={ov['ny_delay_min']} "
      f"c1={ov['cp1_pips']} c2={ov['cp2_pips']} c4={ov['cp4_pips']} mr={ov['min_range']}  "
      f"Net={r['net_pct']:+.1f}% PF={r['pf']:.2f} DD={r['max_dd']:.1f}%")

# ── Stage 2: rerank top 50 on full YM 5yr ─────────────────────────────
p("\nStage 2: YM 5yr full validation of top 50...")
stage2 = []
for _, ov, _ in stage1[:50]:
    r = run_backtest(bars_ym20, 'ct', ov)
    stage2.append((score_r(r), ov, r))

stage2.sort(key=lambda x: -x[0])
p("  Top 5 on YM 5yr:")
for s, ov, r in stage2[:5]:
    p(f"    r={ov['regime_filter']} d={ov['ny_delay_min']} "
      f"c1={ov['cp1_pips']} c2={ov['cp2_pips']} c4={ov['cp4_pips']} mr={ov['min_range']}  "
      f"Net={r['net_pct']:+.1f}% PF={r['pf']:.2f} DD={r['max_dd']:.1f}%")

# ── Stage 3: cross-validate top 15 across all datasets ────────────────
p("\nStage 3: cross-validate top 15 on all 3 datasets...")
wts = [('YM_5yr',3.0),('MT5_4mo',1.5),('USA30_7mo',1.0)]
datasets_map = {
    'YM_5yr':   (bars_ym20,  'ct'),
    'MT5_4mo':  (bars_mt5,   'utc'),
    'USA30_7mo':(bars_usa30, 'utc'),
}
stage3 = []
for _, ov, _ in stage2[:15]:
    res = {n: run_backtest(b, tz, ov) for n,(b,tz) in datasets_map.items()}
    total_sc = sum(score_r(res[n], wt) for n, wt in wts)
    all_ok = all(is_ok(res[n]) for n in res if res[n]['total'] >= 5)
    stage3.append((total_sc, all_ok, ov, res))

stage3.sort(key=lambda x: (-x[1], -x[0]))  # all_ok first, then score

# ── OLD baseline ────────────────────────────────────────────────────────
OLD = {'regime_filter': 400, 'ny_delay_min': 15,
       'cp1_pips': 40, 'cp2_pips': 80, 'cp4_pips': 250, 'min_range': 100}
ro = {n: run_backtest(b, tz, OLD) for n,(b,tz) in datasets_map.items()}
old_sc = sum(score_r(ro[n], wt) for n, wt in wts)
old_ok = all(is_ok(ro[n]) for n in ro if ro[n]['total'] >= 5)

p()
p(f"  {'#':>3}  {'regime':>6} {'delay':>5} {'cp1':>4} {'cp2':>4} {'cp4':>4} {'minR':>5}  "
  f"{'score':>6}  {'YM5y%':>6} {'MT5%':>5} {'USA%':>5}  {'OK':>3}")
p("  " + "-"*72)
p(f"  OLD  {'400':>6} {'15':>5} {'40':>4} {'80':>4} {'250':>4} {'100':>5}  "
  f"{old_sc:6.1f}  "
  f"{ro['YM_5yr']['net_pct']:+5.1f}%  {ro['MT5_4mo']['net_pct']:+4.1f}%  "
  f"{ro['USA30_7mo']['net_pct']:+4.1f}%  {'ALL' if old_ok else '---'}")
p()
for i, (total_sc, all_ok, ov, res) in enumerate(stage3, 1):
    ym = res['YM_5yr']['net_pct']
    mt = res['MT5_4mo']['net_pct']
    us = res['USA30_7mo']['net_pct']
    tag = 'ALL' if all_ok else '---'
    p(f"  {i:3}.  {ov['regime_filter']:6} {ov['ny_delay_min']:5} "
      f"{ov['cp1_pips']:4} {ov['cp2_pips']:4} {ov['cp4_pips']:4} "
      f"{ov.get('min_range',100):5}  {total_sc:6.1f}  "
      f"{ym:+5.1f}%  {mt:+4.1f}%  {us:+4.1f}%  {tag}")

# ── Winner detail ─────────────────────────────────────────────────────────
total_sc, all_ok, ov, _ = stage3[0]
p(f"\n\n=== WINNER: regime={ov['regime_filter']} delay={ov['ny_delay_min']} "
  f"cp1={ov['cp1_pips']} cp2={ov['cp2_pips']} cp4={ov['cp4_pips']} "
  f"min_range={ov.get('min_range',100)} ===")
for name,(b,tz) in datasets_map.items():
    r = run_backtest(b, tz, ov)
    flag = 'PASS' if is_ok(r) else 'FAIL'
    p(f"\n  [{name}] [{flag}]  N={r['total']} WR={r['wr']:.1f}% PF={r['pf']:.2f} "
      f"Net={r['net_pct']:+.1f}% DD={r['max_dd']:.1f}% MC={r['max_consec']}")
    for mk in sorted(r['monthly']):
        v = r['monthly'][mk]
        pct = v / 10000 * 100
        bar = '#' * max(0, int(abs(pct) * 2))
        p(f"    {mk}  {pct:+5.1f}%  {bar}")

out.close()
print("Done. Results in sweep_out.txt")

from data_loader import load_csv
from engine import run_backtest

print("Loading datasets...")
bars_mt5,  _, _ = load_csv('../US30_M1_MT5_JAN_APRIL_10.csv')
bars_ym20, _, _ = load_csv('../ym-1m_bk - 2020-today.csv')
bars_usa30,_, _ = load_csv('../USA30IDXUSD_M1 200000 bars.csv')

# YM 2yr subset (2023-2024) for fast stage-1 sweep
bars_ym_fast = [b for b in bars_ym20 if 2023 <= b['dt'].year <= 2024]
print(f"  MT5={len(bars_mt5):,}  YM_full={len(bars_ym20):,}  YM_fast={len(bars_ym_fast):,}  USA30={len(bars_usa30):,}\n")

def is_ok(r):
    return r['total'] >= 5 and r['pf'] >= 1.3 and r['max_dd'] < 8 and r['net_pct'] > 0

def score_r(r, wt=1.0):
    if r['total'] < 5: return 0.0
    return r['net_pct'] * r['pf'] / max(r['max_dd'], 0.5) * wt

# ── Stage 1: coarse sweep on YM 2yr ──────────────────────────────────────
print("Stage 1: YM 2yr coarse sweep...")
stage1 = []
for regime in [300, 350, 400, 450, 500]:
    for delay in [10, 15, 20, 25]:
        for cp1 in [30, 40, 50]:
            for cp2 in [60, 80, 100]:
                if cp2 <= cp1: continue
                for cp4 in [200, 250, 300]:
                    for min_r in [80, 100, 120]:
                        ov = {'regime_filter': regime, 'ny_delay_min': delay,
                              'cp1_pips': cp1, 'cp2_pips': cp2,
                              'cp4_pips': cp4, 'min_range': min_r}
                        r = run_backtest(bars_ym_fast, 'ct', ov)
                        stage1.append((score_r(r), ov, r))

stage1.sort(key=lambda x: -x[0])
print(f"  {len(stage1)} combos. Top 5 on YM 2yr:")
for s, ov, r in stage1[:5]:
    print(f"    r={ov['regime_filter']} d={ov['ny_delay_min']} "
          f"c1={ov['cp1_pips']} c2={ov['cp2_pips']} c4={ov['cp4_pips']} mr={ov['min_range']}  "
          f"Net={r['net_pct']:+.1f}% PF={r['pf']:.2f} DD={r['max_dd']:.1f}%")

# ── Stage 2: rerank top 50 on full YM 5yr ─────────────────────────────
print("\nStage 2: YM 5yr full validation of top 50...")
stage2 = []
for _, ov, _ in stage1[:50]:
    r = run_backtest(bars_ym20, 'ct', ov)
    stage2.append((score_r(r), ov, r))

stage2.sort(key=lambda x: -x[0])
print(f"  Top 5 on YM 5yr:")
for s, ov, r in stage2[:5]:
    print(f"    r={ov['regime_filter']} d={ov['ny_delay_min']} "
          f"c1={ov['cp1_pips']} c2={ov['cp2_pips']} c4={ov['cp4_pips']} mr={ov['min_range']}  "
          f"Net={r['net_pct']:+.1f}% PF={r['pf']:.2f} DD={r['max_dd']:.1f}%")

# ── Stage 3: cross-validate top 15 across all datasets ────────────────
print("\nStage 3: cross-validate top 15 on all 3 datasets...")
wts = [('YM_5yr',3.0),('MT5_4mo',1.5),('USA30_7mo',1.0)]
datasets_map = {
    'YM_5yr':   (bars_ym20,  'ct'),
    'MT5_4mo':  (bars_mt5,   'utc'),
    'USA30_7mo':(bars_usa30, 'utc'),
}
stage3 = []
for _, ov, _ in stage2[:15]:
    res = {n: run_backtest(b, tz, ov) for n,(b,tz) in datasets_map.items()}
    total_sc = sum(score_r(res[n], wt) for n, wt in wts)
    all_ok = all(is_ok(res[n]) for n in res if res[n]['total'] >= 5)
    stage3.append((total_sc, all_ok, ov, res))

stage3.sort(key=lambda x: (-x[1], -x[0]))  # all_ok first, then score

# ── OLD baseline ────────────────────────────────────────────────────────
OLD = {'regime_filter': 400, 'ny_delay_min': 15,
       'cp1_pips': 40, 'cp2_pips': 80, 'cp4_pips': 250, 'min_range': 100}
ro = {n: run_backtest(b, tz, OLD) for n,(b,tz) in datasets_map.items()}
old_sc = sum(score_r(ro[n], wt) for n, wt in wts)
old_ok = all(is_ok(ro[n]) for n in ro if ro[n]['total'] >= 5)

print(f"\n  {'#':>3}  {'regime':>6} {'delay':>5} {'cp1':>4} {'cp2':>4} {'cp4':>4} {'minR':>5}  "
      f"{'score':>6}  {'YM5y%':>6} {'MT5%':>5} {'USA%':>5}  {'OK':>3}")
print("  " + "-"*72)
print(f"  OLD  {'400':>6} {'15':>5} {'40':>4} {'80':>4} {'250':>4} {'100':>5}  "
      f"{old_sc:6.1f}  "
      f"{ro['YM_5yr']['net_pct']:+5.1f}%  {ro['MT5_4mo']['net_pct']:+4.1f}%  "
      f"{ro['USA30_7mo']['net_pct']:+4.1f}%  {'ALL' if old_ok else '---'}")
print()
for i, (total_sc, all_ok, ov, res) in enumerate(stage3, 1):
    ym = res['YM_5yr']['net_pct']
    mt = res['MT5_4mo']['net_pct']
    us = res['USA30_7mo']['net_pct']
    tag = 'ALL' if all_ok else '---'
    print(f"  {i:3}.  {ov['regime_filter']:6} {ov['ny_delay_min']:5} "
          f"{ov['cp1_pips']:4} {ov['cp2_pips']:4} {ov['cp4_pips']:4} "
          f"{ov.get('min_range',100):5}  {total_sc:6.1f}  "
          f"{ym:+5.1f}%  {mt:+4.1f}%  {us:+4.1f}%  {tag}")

# ── Winner detail ─────────────────────────────────────────────────────────
total_sc, all_ok, ov, _ = stage3[0]
print(f"\n\n=== WINNER: regime={ov['regime_filter']} delay={ov['ny_delay_min']} "
      f"cp1={ov['cp1_pips']} cp2={ov['cp2_pips']} cp4={ov['cp4_pips']} "
      f"min_range={ov.get('min_range',100)} ===")
for name,(b,tz) in datasets_map.items():
    r = run_backtest(b, tz, ov)
    flag = 'PASS' if is_ok(r) else 'FAIL'
    print(f"\n  [{name}] [{flag}]  N={r['total']} WR={r['wr']:.1f}% PF={r['pf']:.2f} "
          f"Net={r['net_pct']:+.1f}% DD={r['max_dd']:.1f}% MC={r['max_consec']}")
    for mk in sorted(r['monthly']):
        v = r['monthly'][mk]
        pct = v / 10000 * 100
        bar = '#' * max(0, int(abs(pct) * 2))
        print(f"    {mk}  {pct:+5.1f}%  {bar}")

print("\nDone.")

wts = [('YM_5yr',3.0),('MT5_4mo',1.5),('USA30_7mo',1.0)]
datasets_map = {'YM_5yr':(bars_ym20,'ct'),'MT5_4mo':(bars_mt5,'utc'),'USA30_7mo':(bars_usa30,'utc')}
stage2 = []
for _, ov, _ in stage1[:30]:
    res = {n: run_backtest(b, tz, ov) for n,(b,tz) in datasets_map.items()}
    total_sc = sum(score_r(res[n], wt) for n, wt in wts)
    all_ok = all(is_ok(res[n]) for n in res if res[n]['total'] >= 5)
    stage2.append((total_sc, all_ok, ov, res))

stage2.sort(key=lambda x: (-x[1], -x[0]))  # all_ok first, then score

# ── OLD baseline ────────────────────────────────────────────────────────
OLD = {'regime_filter': 400, 'ny_delay_min': 15,
       'cp1_pips': 40, 'cp2_pips': 80, 'cp4_pips': 250, 'min_range': 100}
ro = {n: run_backtest(b, tz, OLD) for n,(b,tz) in datasets_map.items()}
old_sc = sum(score_r(ro[n], wt) for n, wt in wts)
old_ok = all(is_ok(ro[n]) for n in ro if ro[n]['total'] >= 5)

print(f"\n  {'#':>3}  {'regime':>6} {'delay':>5} {'cp1':>4} {'cp2':>4} {'cp4':>4} {'minR':>5}  "
      f"{'score':>6}  {'YM5y':>6} {'MT5':>6} {'USA':>6}  {'OK':>2}")
print("  " + "-"*77)
print(f"  OLD  {'400':>6} {'15':>5} {'40':>4} {'80':>4} {'250':>4} {'100':>5}  "
      f"{old_sc:6.1f}  "
      f"{ro['YM_5yr']['net_pct']:+5.1f}%  {ro['MT5_4mo']['net_pct']:+5.1f}%  "
      f"{ro['USA30_7mo']['net_pct']:+5.1f}%  {'ALL' if old_ok else '---'}")
print()
for i, (total_sc, all_ok, ov, res) in enumerate(stage2[:20], 1):
    ym = res['YM_5yr']['net_pct']
    mt = res['MT5_4mo']['net_pct']
    us = res['USA30_7mo']['net_pct']
    tag = 'ALL' if all_ok else '   '
    print(f"  {i:3}.  {ov['regime_filter']:6} {ov['ny_delay_min']:5} "
          f"{ov['cp1_pips']:4} {ov['cp2_pips']:4} {ov['cp4_pips']:4} "
          f"{ov.get('min_range',100):5}  {total_sc:6.1f}  "
          f"{ym:+5.1f}%  {mt:+5.1f}%  {us:+5.1f}%  {tag}")

# ── Winner detail ─────────────────────────────────────────────────────────
total_sc, all_ok, ov, _ = stage2[0]
print(f"\n\n=== WINNER: regime={ov['regime_filter']} delay={ov['ny_delay_min']} "
      f"cp1={ov['cp1_pips']} cp2={ov['cp2_pips']} cp4={ov['cp4_pips']} "
      f"min_range={ov.get('min_range',100)} ===")
for name,(b,tz) in datasets_map.items():
    r = run_backtest(b, tz, ov)
    flag = 'PASS' if is_ok(r) else 'FAIL'
    print(f"\n  [{name}] [{flag}]  N={r['total']} WR={r['wr']:.1f}% PF={r['pf']:.2f} "
          f"Net={r['net_pct']:+.1f}% DD={r['max_dd']:.1f}% MC={r['max_consec']}")
    for mk in sorted(r['monthly']):
        v = r['monthly'][mk]
        pct = v / 10000 * 100
        bar = '#' * max(0, int(abs(pct) * 2))
        print(f"    {mk}  {pct:+5.1f}%  {bar}")

print("\nDone.")

