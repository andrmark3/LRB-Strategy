import sys; sys.path.insert(0,'.')
from data_loader import load_csv
from engine import run_backtest

bars, tz, fmt = load_csv('../US30_M1_MT5_JAN_APRIL_10.csv')

# Best so far: regime=600,delay=30,cp4=300,min_range=120,sl=100,cp1=50,cp2=100
# Test cp3
base = {'regime_filter': 600, 'ny_delay_min': 30, 'cp4_pips': 300,
        'min_range': 120, 'sl_pips': 100, 'cp1_pips': 50, 'cp2_pips': 100}
results = []
for cp3 in [100, 120, 150, 180, 200]:
    ov = {**base, 'cp3_pips': cp3}
    r = run_backtest(bars, 'utc', ov)
    print(f"cp3={cp3:3}  N={r['total']:2}  WR={r['wr']:5.1f}%  PF={r['pf']:5.2f}  net={r['net_pct']:+5.1f}%  DD={r['max_dd']:.1f}%  MC={r['max_consec']}")

print()
print('--- Full trace of best config (cp1=50, cp2=100, cp3=120, cp4=300) ---')
ov = {**base, 'cp3_pips': 120}
r = run_backtest(bars, 'utc', ov)
for t in r['trades']:
    print(f"  {t['date']}  {t['dir']:4}  {t['time']}  {t['pips']:+7.1f}p  {t['outcome']:4}  {t['reason']}")
print()
for mk in sorted(r['monthly']):
    print(f"  {mk}: {r['monthly'][mk]:+.0f}$")


