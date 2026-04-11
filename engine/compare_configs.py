import sys; sys.path.insert(0,'.')
from data_loader import load_csv
from engine import run_backtest

bmt, _, _ = load_csv('../US30_M1_MT5_JAN_APRIL_10.csv')
bym, _, _ = load_csv('../ym-1m_bk - 2020-today.csv')
bus, _, _ = load_csv('../USA30IDXUSD_M1 200000 bars.csv')

configs = [
    ('CUR  cp2=80  cp4=250', {'cp2_pips': 80,  'cp4_pips': 250}),
    ('#1   cp2=80  cp4=350', {'cp2_pips': 80,  'cp4_pips': 350}),
    ('#4   cp2=100 cp4=350', {'cp2_pips': 100, 'cp4_pips': 350}),
    ('     cp2=100 cp4=300', {'cp2_pips': 100, 'cp4_pips': 300}),
]
print(f"{'Config':24}  {'YM_PF':>6} {'YM_Net':>8} {'YM_DD':>6}  {'MT5_PF':>6} {'MT5_Net':>8} {'MT5_DD':>6}  {'US_PF':>6} {'US_Net':>8} {'US_DD':>6}")
print("-"*100)
for lbl, ov in configs:
    ry  = run_backtest(bym,  'ct',  ov)
    rmt = run_backtest(bmt,  'utc', ov)
    rus = run_backtest(bus,  'utc', ov)
    print(f"{lbl:24}  {ry['pf']:6.2f} {ry['net_pct']:+7.1f}% {ry['max_dd']:5.1f}%  "
          f"{rmt['pf']:6.2f} {rmt['net_pct']:+7.1f}% {rmt['max_dd']:5.1f}%  "
          f"{rus['pf']:6.2f} {rus['net_pct']:+7.1f}% {rus['max_dd']:5.1f}%")
    # Monthly breakdown for MT5 @ 1.0% risk
    r10 = run_backtest(bmt, 'utc', {**ov, 'risk_per_leg_pct': 1.0})
    months = {k: v/10000*100 for k,v in r10['monthly'].items()}
    details = '  '.join(f"{mk}={v:+.1f}%" for mk,v in sorted(months.items()))
    print(f"  MT5 @1.0%: {details}")
