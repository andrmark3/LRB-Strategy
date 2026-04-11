"""
FTMO Challenge Analysis
Evaluates monthly P&L distribution at different risk levels and sweeps for
parameters that maximise the probability of passing FTMO in 2-3 weeks.

FTMO Phase 1 rules:
  Profit target : 10% of starting balance
  Max daily loss : 5% of starting balance
  Max overall DD : 10% of starting balance
  Min trading days: 4

Key insight: at 1.0%/leg risk, monthly pnl = 2x the 0.5% results.
For 10% target in 1 month, need ~5% net at 0.5% risk in that month.
"""
import sys, os
sys.path.insert(0, '.')
from data_loader import load_csv
from engine import run_backtest

out = open('ftmo_out.txt', 'w', encoding='utf-8')
def p(s=''):
    print(s); print(s, file=out); out.flush()

p("Loading datasets...")
bars_mt5,  _, _ = load_csv('../US30_M1_MT5_JAN_APRIL_10.csv')
bars_ym20, _, _ = load_csv('../ym-1m_bk - 2020-today.csv')
bars_usa30,_, _ = load_csv('../USA30IDXUSD_M1 200000 bars.csv')
p(f"  MT5={len(bars_mt5):,}  YM={len(bars_ym20):,}  USA30={len(bars_usa30):,}\n")

# ── Section 1: Current params monthly breakdown at 1.0% risk ──────────────
p("="*65)
p("SECTION 1: Current params (v2.7.0) at 1.0% risk/leg (FTMO Phase 1)")
p("="*65)
for label, bars, tz in [
    ('YM 2020-2022   ', bars_ym20, 'ct'),
    ('MT5 Jan-Apr 2026', bars_mt5, 'utc'),
    ('USA30 Sep25-Apr26', bars_usa30, 'utc'),
]:
    r = run_backtest(bars, tz, {'risk_per_leg_pct': 1.0})
    months = {k: v / 10000 * 100 for k, v in r['monthly'].items()}
    nmo = len(months)
    passing = [(mk, v) for mk, v in months.items() if v >= 10.0]
    near    = [(mk, v) for mk, v in months.items() if 7.0 <= v < 10.0]
    negative = [(mk, v) for mk, v in months.items() if v < 0]
    p(f"\n  [{label}]")
    p(f"  WR={r['wr']}%  PF={r['pf']}  Net={r['net_pct']:+.1f}%  DD={r['max_dd']:.1f}%  T={r['total']}")
    p(f"  Months: {nmo} total | >=10%: {len(passing)} ({len(passing)/nmo*100:.0f}%) | "
      f"7-10%: {len(near)} ({len(near)/nmo*100:.0f}%) | <0%: {len(negative)} ({len(negative)/nmo*100:.0f}%)")
    for mk in sorted(months):
        v = months[mk]
        bar = '#' * max(0, int(abs(v) * 1.5))
        flag = ' <-- FTMO PASS' if v >= 10.0 else (' <-- near' if v >= 7.0 else (' <--LOSS' if v < -3.0 else ''))
        p(f"    {mk}  {v:+5.1f}%  {bar}{flag}")

# ── Section 2: FTMO sweep ──────────────────────────────────────────────────
p("\n\n" + "="*65)
p("SECTION 2: Parameter sweep — maximise FTMO passing months (>=10% at 1%)")
p("                             across YM 3yr + USA30 7mo datasets")
p("="*65)

def ftmo_score(bars, tz, ov):
    """Score a config specifically for FTMO: count of months >= 5% at 0.5% risk (= 10% at 1%)."""
    r = run_backtest(bars, tz, ov)
    if r['total'] < 5: return 0, 0, r
    months = list(r['monthly'].values())
    # At 0.5% risk, >=5% monthly => FTMO-passing month at 1.0% risk
    # Scale factor: 0.5% base
    pct_months = [v / 10000 * 100 for v in months]
    n_passing = sum(1 for v in pct_months if v >= 5.0)    # passes at 1.0% risk
    n_near    = sum(1 for v in pct_months if 3.5 <= v < 5.0)  # near-pass
    n_neg     = sum(1 for v in pct_months if v < -2.5)     # danger months at 1% risk (-5%)
    # Score: reward passing months, reward near-passes, penalise dangerous months
    score = n_passing * 3.0 + n_near * 1.0 - n_neg * 2.0 + r['pf']
    return score, n_passing, r

base = {'risk_per_leg_pct': 0.5}  # sweep at 0.5%, scale mentally to 1.0%
sweep_results = []

p("\nSweeping (YM+USA30)... this may take a few minutes.")
combo_count = 0
for regime in [300, 350, 400, 450, 500]:
    for delay in [10, 15, 20]:
        for cp1 in [30, 40, 50]:
            for cp2 in [60, 80, 100]:
                if cp2 <= cp1: continue
                for cp4 in [200, 250, 300, 350]:
                    for min_r in [80, 100]:
                        ov = {**base, 'regime_filter': regime, 'ny_delay_min': delay,
                              'cp1_pips': cp1, 'cp2_pips': cp2,
                              'cp4_pips': cp4, 'min_range': min_r}
                        sc_ym,  np_ym,  r_ym  = ftmo_score(bars_ym20,  'ct',  ov)
                        sc_us,  np_us,  r_us  = ftmo_score(bars_usa30, 'utc', ov)
                        # Combined score: YM has more months so weight it more
                        total_sc = sc_ym * 2 + sc_us
                        total_np = np_ym + np_us
                        # Must have robust PF on both
                        if r_ym['pf'] < 1.2 or r_us['pf'] < 1.1: continue
                        if r_ym['max_dd'] > 8 or r_us['max_dd'] > 8: continue
                        sweep_results.append((total_sc, total_np, ov, r_ym, r_us))
                        combo_count += 1

sweep_results.sort(key=lambda x: (-x[0], -x[1]))
p(f"  {combo_count} valid combos tested.\n")

p(f"\n  {'#':>3}  {'regime':>6} {'delay':>5} {'cp1':>4} {'cp2':>4} {'cp4':>4} {'minR':>5}  "
  f"{'score':>6}  {'ftmo_mo':>7}  {'YM_pf':>6} {'YM_net':>7}  {'US_pf':>6} {'US_net':>7}")
p("  " + "-"*88)

# Baseline (current v2.7.0)
ov0 = {**base}
sc0_ym, np0_ym, r0_ym = ftmo_score(bars_ym20, 'ct', ov0)
sc0_us, np0_us, r0_us = ftmo_score(bars_usa30, 'utc', ov0)
p(f"  CUR  {'400':>6} {'15':>5} {'40':>4} {'80':>4} {'250':>4} {'100':>5}  "
  f"{sc0_ym*2+sc0_us:6.1f}  {np0_ym+np0_us:7}  "
  f"{r0_ym['pf']:6.2f} {r0_ym['net_pct']:+6.1f}%  "
  f"{r0_us['pf']:6.2f} {r0_us['net_pct']:+6.1f}%")
p()

for i, (total_sc, total_np, ov, r_ym, r_us) in enumerate(sweep_results[:25], 1):
    p(f"  {i:3}.  {ov['regime_filter']:6} {ov['ny_delay_min']:5} "
      f"{ov['cp1_pips']:4} {ov['cp2_pips']:4} {ov['cp4_pips']:4} "
      f"{ov.get('min_range',100):5}  {total_sc:6.1f}  {total_np:7}  "
      f"{r_ym['pf']:6.2f} {r_ym['net_pct']:+6.1f}%  "
      f"{r_us['pf']:6.2f} {r_us['net_pct']:+6.1f}%")

# ── Section 3: Winner detail + MT5 cross-check ────────────────────────────
p("\n\n" + "="*65)
p("SECTION 3: Top winner — full detail + MT5 cross-check")
p("="*65)
total_sc, total_np, ov_win, _, _ = sweep_results[0]

for label, bars, tz in [
    ('YM 2020-2022   ', bars_ym20, 'ct'),
    ('MT5 Jan-Apr 2026', bars_mt5, 'utc'),
    ('USA30 Sep25-Apr26', bars_usa30, 'utc'),
]:
    r05 = run_backtest(bars, tz, ov_win)
    r10 = run_backtest(bars, tz, {**ov_win, 'risk_per_leg_pct': 1.0})
    months = {k: v / 10000 * 100 for k, v in r10['monthly'].items()}
    nmo = len(months)
    passing = sum(1 for v in months.values() if v >= 10.0)
    ok_flag = 'PASS' if r05['pf'] >= 1.3 and r05['max_dd'] < 8 and r05['net_pct'] > 0 else 'FAIL'
    p(f"\n  [{label}] [{ok_flag}]")
    p(f"  @0.5%: WR={r05['wr']}%  PF={r05['pf']}  Net={r05['net_pct']:+.1f}%  DD={r05['max_dd']:.1f}%  T={r05['total']}")
    p(f"  @1.0%: WR={r10['wr']}%  PF={r10['pf']}  Net={r10['net_pct']:+.1f}%  DD={r10['max_dd']:.1f}%  FTMO months={passing}/{nmo}")
    for mk in sorted(months):
        v = months[mk]
        bar = '#' * max(0, int(abs(v) * 1.5))
        flag = ' <-- FTMO PASS' if v >= 10.0 else (' <-- near' if v >= 7.0 else (' <-- LOSS' if v < -3.0 else ''))
        p(f"    {mk}  {v:+5.1f}%  {bar}{flag}")

p(f"\n\nWINNER PARAMS: {ov_win}")
p("\nDone. Results in ftmo_out.txt")
out.close()
