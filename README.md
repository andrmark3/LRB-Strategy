# LRB Strategy — London Range Breakout V2

**FTMO-ready semi-automated trading system for US30 / YM Dow Jones futures.**

Developed and optimised through live backtesting on 3+ years of real M1 data.

---

## Architecture

```
LRB_Strategy/
├── engine/
│   ├── config.py          # All parameters — change here, everything stays in sync
│   ├── data_loader.py     # CSV parsers (backtestmarket, bluecapital, MT5, TV)
│   ├── filters.py         # Trend, regime, sweep, NY-delay, FTMO-guard (pure functions)
│   ├── trade_manager.py   # T1/T2 checkpoint management
│   └── engine.py          # Core backtest loop — run this directly
│
├── backtester/
│   └── LRB_V2.html        # Browser UI — drop CSV, click Run (place file here)
│
├── mt5/
│   ├── LRB_V2_EA.mq5      # Expert Advisor (semi-auto, human confirms entry)
│   └── LRB_V2_EA.mqh      # Shared constants
│
├── tests/
│   └── test_engine.py     # Sanity checks — run before every commit
│
└── data/                  # Put your CSV files here (gitignored)
```

---

## Quick Start

```bash
# Run a backtest
cd engine
python engine.py --data ../data/ym-1m.csv --tz ct
python engine.py --data ../data/US30_M1.csv --tz utc --delay 15 --regime 500 --trace

# Run tests
python tests/test_engine.py
```

Open `backtester/LRB_V2.html` in any browser for the visual UI.

---

## Validated Results

| Dataset | WR | PF | Net | Max DD | Sharpe |
|---|---|---|---|---|---|
| YM 2020–2022 (3yr) | 46% | 1.50 | +50.9% | 6.5% | 2.56 |
| MT5 Jan–Apr 2026 | 56% | 2.91 | +6.6% | 2.0% | 6.65 |

---

## Key Fixes (v2.0.1)

| Fix | Effect | Why |
|---|---|---|
| NY open delay 15min | Eliminated all 3 March 2026 losses | Entries at 14:32–14:47 UTC = opening noise |
| Regime filter 500p | Skips hostile volatility months | March 2026 avg range was 433–640p |
| Trend min 10 closes | More reliable direction signals | 3-close minimum was too noisy |
| Trend pos clamped 0–1 | No negative position ratios | New-low days caused pos < 0 |

---

## FTMO Challenge

| Phase | Target | Max DD | Risk per Leg |
|---|---|---|---|
| Phase 1 | 8% in 30 days | 10% | 1.0% |
| Phase 2 | 5% in 60 days | 5% | 0.5% |
| Funded | preserve capital | 10% | 0.5–0.75% |

---

## Collaboration with Claude

The modular architecture means targeted edits, not full file rewrites:
- Change a filter → edit `engine/filters.py` (130 lines, not 1400)
- Test a change → `python engine.py` in seconds
- MT5 update → translate Python function 1:1 to MQL5

See [CHANGELOG.md](CHANGELOG.md) for full version history.
