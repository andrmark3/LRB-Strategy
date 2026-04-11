"""
LRB Strategy — Central Configuration
All strategy parameters in one place.
Change here, engine + MT5 EA stay in sync.

PARAMETER HISTORY:
  regime_filter: 500p → 400p (2026-04-07)
  2026-05 v2.6.0 overfitting experiment (REVERTED in v2.7.0):
    regime_filter: 400 → 600  (overfit to 4-month MT5 window — REVERTED)
    ny_delay_min:   15 → 30   (overfit — REVERTED)
    min_range:     100 → 120  (overfit — REVERTED)
    cp1_pips:       40 → 50   (overfit — REVERTED)
    cp2_pips:       80 → 100  (overfit — REVERTED)
    cp4_pips:      250 → 300  (overfit — REVERTED)
  2026-05 v2.8.0 FTMO optimisation sweep (3-dataset cross-validated):
    cp2_pips:   80 → 100  (T1 captures full 100p move before closing)
    cp4_pips:  250 → 350  (T2 target 1:3.5 R/R — rides strong trend days)
    Result across all 3 datasets: YM PF 1.48→1.58, Net +37.5%→+46.5%, DD 4.6%→4.3%
                                  MT5 PF 3.87→4.15, Net +6.9%→+7.5%
                                  USA30 PF 1.57→1.84, Net +5.4%→+8.0%
    FTMO (1.0% risk): MT5 Feb 2026 = +10.7% — passes 10% target.
"""

# ── SESSION HOURS (UTC) ────────────────────────────────────────────────────
# For CT data (backtestmarket), engine auto-adjusts via TIMEZONE_PRESETS
SESSION = {
    "london_start": 8,    # 08:00 UTC = 02:00 CT
    "london_end":   14,   # 14:00 UTC = 08:00 CT
    "ny_open_h":    14,
    "ny_open_m":    30,   # NY open: 14:30 UTC
    "ny_delay_min": 15,   # Skip first 15min of NY open
    "ny_close_h":   21,   # 21:00 UTC = 15:00 CT
}

# ── FILTERS ─────────────────────────────────────────────────────────────────
FILTERS = {
    "min_range":        100,   # pips — skip choppy days
    "max_range":        400,   # pips — skip single-day news/high-vol
    "regime_filter":    400,   # pips — skip day if 5d avg range > this
    # 400p: validated robust across 5yr+ data (regime=600 was overfit to 4mo)
    "regime_lookback":  5,     # trading days for rolling avg
    "trend_lb":         20,    # trading days for 20d high/low position
    "trend_min_closes": 10,    # min prior closes before trusting trend
    "trend_up_pos":     0.60,  # price > 60% of 20d range → BUY only
    "trend_dn_pos":     0.40,  # price < 40% of 20d range → SELL only
    "confirm_bars":     1,     # bars beyond range to confirm breakout
    "require_sweep":    True,  # price must fake-break range first
    "skip_weekends":    True,
}

# ── TRADE MANAGEMENT ────────────────────────────────────────────────────────
TRADE = {
    "sl_pips":   100,    # Stop loss in pips
    "cp1_pips":   40,    # +40p: move T1+T2 SL to entry (breakeven)
    "cp2_pips":  100,    # +100p: close T1 at profit; T2 SL → entry+40p
    "cp3_pips":  120,    # +120p: trail T2 SL → entry+100p
    "cp4_pips":  350,    # +350p: close T2 (full target, 1:3.5 R/R)
    "spread":      2,    # pips — US30 typical spread
    "slippage":    1,    # pips — entry slippage estimate
}

# ── RISK MANAGEMENT ─────────────────────────────────────────────────────────
RISK = {
    "risk_per_leg_pct": 0.5,   # % of account per leg (T1 and T2 each)
    # Total risk per setup = risk_per_leg_pct * 2
    # FTMO Phase 1: use 1.0%/leg  |  Phase 2: use 0.5%/leg
    "ftmo_daily_guard": 4.0,   # % — block new entries if daily loss > this
    "ftmo_max_dd":      8.0,   # % — halt trading if total DD > this
    "reduce_risk_at_dd":4.0,   # % — halve risk if DD > this
}

# ── ACCOUNT ─────────────────────────────────────────────────────────────────
ACCOUNT = {
    "balance":  10_000,
    "currency": "USD",
    "verbose":  False,   # True = print every trade to console
}

# ── TIMEZONE PRESETS ─────────────────────────────────────────────────────────
TIMEZONE_PRESETS = {
    "ct":  {"london_start": 2,  "london_end": 8,  "ny_open_h": 8,  "ny_close_h": 15},
    "utc": {"london_start": 8,  "london_end": 14, "ny_open_h": 14, "ny_close_h": 21},
    "ny":  {"london_start": 3,  "london_end": 9,  "ny_open_h": 9,  "ny_close_h": 16},
}

