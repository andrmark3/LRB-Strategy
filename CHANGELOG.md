# Changelog

## [2.0.1] — 2026-04-07
### Fixed
- **NY open delay (15min)**: eliminated all 3 March 2026 SL hits caused by opening noise (entries at 14:32–14:47 UTC)
- **Regime filter (500p)**: auto-skip hostile volatility months. March 2026 avg 433p → filter blocked trading → 0 losses
- **Trend min closes (10)**: require 10 prior days before trusting direction (was 3 — too noisy)
- **Trend position clamped 0–1**: prevents negative pos values when price makes new lows below lookback window
- **MT5 export parser**: full support for `<DATE>\t<TIME>` format with `YYYY.MM.DD` dot-dates
- **Short file warning**: orange banner when < 60 trading days loaded in HTML backtester

### Architecture
- Separated monolithic 1400-line HTML into modular Python engine
- `engine/filters.py`: all filters as pure testable functions
- `engine/trade_manager.py`: T1/T2 checkpoint logic isolated
- `engine/config.py`: single source of truth for all parameters
- `engine/data_loader.py`: all CSV format parsers consolidated
- `engine/engine.py`: CLI backtest runner
- GitHub MCP integration: Claude can now read/write files directly

---

## [2.0.0] — 2026-03-15
### Added
- Liquidity sweep filter (Phase 1: fake break, Phase 2: real breakout)
- Spread + slippage simulation (2pt + 1pt for US30 FTMO realism)
- FTMO daily guard (auto-pause if daily loss approaches limit)
- MT5 semi-automation EA scaffold

### Changed (from 486-config sweep on real data)
- Confirm bars: 2 → 1 (sweep is the quality filter)
- CP1: 50p → 40p (earlier BE reduces full -100p losses)
- CP4: 200p → 250p (captures larger post-sweep moves)

### Validated
- YM 2020–22: WR=46%, PF=1.50, Net=+50.9%, DD=6.5%, Sharpe=2.56
- MT5 Jan–Apr 2026 (with fixes): WR=56%, PF=2.91, Net=+6.6%, DD=2.0%

---

## [1.0.0] — 2025-12-01
### Initial V1
- Basic London range breakout with trend filter and max range cap
- YM 2020–22: WR=31%, PF=1.47, Net=+38.6%, DD=3.6%
