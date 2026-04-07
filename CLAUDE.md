# CLAUDE.md — Session Briefing for Claude

> **READ THIS FIRST every session before touching any code.**
> This file replaces the need to re-explain the project context each time.

---

## What This Project Is

London Range Breakout (LRB) V2 — a semi-automated FTMO prop-firm trading strategy for US30 / YM Dow Jones futures.

The **Python engine is the single source of truth**. The HTML backtester and MT5 EA both implement the same logic. When anything changes, change Python first, then propagate to HTML/MQ5.

---

## Architecture (read before editing anything)

```
engine/config.py        ← ALL parameters live here. Change here first.
engine/filters.py       ← All filter logic (trend, regime, sweep, NY-delay)
engine/trade_manager.py ← T1+T2 checkpoint management
engine/data_loader.py   ← CSV parsers for all data sources
engine/engine.py        ← CLI backtest runner. Imports everything above.
tests/test_engine.py    ← Run after every change to filters or trade_manager
backtester/LRB_V2.html ← Browser UI (JS mirrors Python logic)
mt5/LRB_V2_EA.mq5      ← MT5 Expert Advisor (MQL5 mirrors Python logic)
```

**Token-efficient edit pattern:**
1. Read only the file being changed (use `github:get_file_contents`)
2. Make the targeted change
3. Push with `github:create_or_update_file` (include the SHA)
4. Do NOT read files you don't need to change

---

## Current Validated Results (do not regress below these)

| Dataset | WR | PF | Net | Max DD | Sharpe |
|---|---|---|---|---|---|
| YM 2020–2022 (3yr) | 46% | 1.50 | +50.9% | 6.5% | 2.56 |
| MT5 Jan–Apr 2026 (with fixes) | 56% | 2.91 | +6.6% | 2.0% | 6.65 |

**Minimum acceptable bar:** PF > 1.3, Max DD < 8%, all years profitable.

---

## Key Parameters (current optimized values)

| Param | Value | Why |
|---|---|---|
| London session | 08:00–14:00 UTC / 02:00–08:00 CT | Session definition |
| NY open delay | **15 min** | Eliminates opening-noise losses |
| Regime filter | **500p** (5d avg) | Skips hostile vol months (March 2026) |
| Trend min closes | **10** | Prevents noisy signals from short files |
| Confirm bars | **1** | After sweep — enough after extensive testing |
| CP1 / CP2 / CP3 / CP4 | **40 / 80 / 120 / 250p** | Optimized from 486-config sweep |
| SL | 100p | Fixed |
| Risk per leg | 0.5% (Phase 2) / 1.0% (Phase 1) | FTMO limits |
| Max Range | 400p | Skip news days |

---

## Data Sources & Timezones

| File pattern | Source | Timezone | Notes |
|---|---|---|---|
| `ym-1m_bk_*.csv` | backtestmarket.com | **Chicago CT** | Use `--tz ct` |
| `USA30IDXUSD_M1*.csv` | bluecapitaltrading.com | **UTC** | Download 200k+ bars |
| `US30_M1_*.csv` | MT5 export | **UTC** | Standard MT5 TAB format |

---

## Known Issues & Next Work (check GitHub Issues for details)

See: https://github.com/andrmark3/LRB-Strategy/issues

---

## How to Run a Backtest

```bash
cd engine
# YM 3yr (main validation dataset)
python engine.py --data ../data/ym-1m_bk_-_2020-today.csv --tz ct

# MT5 2026 with all fixes
python engine.py --data ../data/US30_M1_202601020100_202604031614.csv --tz utc --delay 15 --regime 500

# With trace (every trade printed)
python engine.py --data ../data/ym.csv --tz ct --trace

# Test a parameter change quickly
python engine.py --data ../data/ym.csv --tz ct --risk 1.0 --regime 450
```

## How to Run Tests

```bash
python tests/test_engine.py
```

All 7 tests must pass before committing any change to filters.py or trade_manager.py.

---

## MT5 EA Status

- File: `mt5/LRB_V2_EA.mq5`
- Status: **scaffold complete, needs live testing**
- Architecture: semi-auto state machine (IDLE → WAITING_SWEEP → WAITING_HUMAN → MANAGING)
- All parameters mirror `engine/config.py` exactly
- `CalcRegimeAvg()` uses D1 bars (approximate — needs refinement for live)
- `CalcTrend()` uses D1 bars close prices (matches Python logic)

---

## Claude Session Protocol

**Start of session:**
1. Read this file (CLAUDE.md) — done
2. Check open GitHub Issues for current task
3. Read only the specific file(s) needed for the task
4. Make change → push → confirm SHA updated

**Do NOT:**
- Read all files at once (token waste)
- Re-explain what LRB strategy is (it's here)
- Re-explain the architecture (it's here)
- Push without the file SHA when updating existing files (will fail)

**Commit message format:**
```
type(scope): short description

type: fix | feat | test | refactor | docs | perf
scope: filters | trade_mgr | engine | mt5 | config | data | tests | html

Examples:
  fix(filters): raise regime threshold to 450p — reduces hostile month trades
  feat(trade_mgr): add re-entry logic after BE stop
  perf(engine): cache sorted_dates.index() lookups
```
