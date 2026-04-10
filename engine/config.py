"""
LRB Strategy — Central Configuration
All strategy parameters in one place.
Change here, engine + MT5 EA stay in sync.

PARAMETER HISTORY:
  regime_filter: 500p → 400p (2026-04-07)
  2026-05 optimisation sweep on MT5 Jan-Apr 2026 data:
    regime_filter: 400 → 600  (allows trending March months)
    ny_delay_min:   15 → 30   (cleaner NY entries)
    min_range:     100 → 120  (skip low-quality choppy days)
    cp1_pips:       40 → 50   (wider BE zone)
    cp2_pips:       80 → 100  (T1 locks at 100p)
    cp4_pips:      250 → 300  (higher T2 target = 1:3 R/R)
  Result: 20 trades, WR=60%, PF=6.03, Net=+12.3%, DD=1.0%, MC=1
"""

# ── SESSION HOURS (UTC) ────────────────────────────────────────────────────
# For CT data (backtestmarket), engine auto-adjusts via TIMEZONE_PRESETS
SESSION = {
    "london_start": 8,    # 08:00 UTC = 02:00 CT
    "london_end":   14,   # 14:00 UTC = 08:00 CT
    "ny_open_h":    14,
    "ny_open_m":    30,   # NY open: 14:30 UTC
    "ny_delay_min": 30,   # Skip first 30min of NY open — cleaner entries
    "ny_close_h":   21,   # 21:00 UTC = 15:00 CT
}

# ── FILTERS ─────────────────────────────────────────────────────────────────
FILTERS = {
    "min_range":        120,   # pips — skip choppy days (< 120p = low quality)
    "max_range":        400,   # pips — skip single-day news/high-vol
    "regime_filter":    600,   # pips — skip day if 5d avg range > this
    # 600p: wide enough to allow trending March/volatile months
    "regime_lookback":  5,     # trading days for rolling avg
    "trend_lb":         20,    # trading days for 20d high/low position
    "trend_min_closes": 10,    # min prior closes before trusting trend ← KEY FIX
    "trend_up_pos":     0.60,  # price > 60% of 20d range → BUY only
    "trend_dn_pos":     0.40,  # price < 40% of 20d range → SELL only
    "confirm_bars":     1,     # bars beyond range to confirm breakout
    "require_sweep":    True,  # price must fake-break range first
    "skip_weekends":    True,
}

# ── TRADE MANAGEMENT ────────────────────────────────────────────────────────
TRADE = {
    "sl_pips":   100,    # Stop loss in pips
    "cp1_pips":   50,    # +50p: move T1+T2 SL to entry (breakeven)
    "cp2_pips":  100,    # +100p: close T1 at profit; T2 SL → entry+50p
    "cp3_pips":  120,    # +120p: trail T2 SL → entry+100p
    "cp4_pips":  300,    # +300p: close T2 (full target, 1:3.0 R/R)
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
