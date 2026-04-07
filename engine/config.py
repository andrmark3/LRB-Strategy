"""
LRB Strategy — Central Configuration
All strategy parameters in one place.
Change here, engine + MT5 EA stay in sync.
"""

# ── SESSION HOURS (UTC) ────────────────────────────────────────────────────
# For CT data (backtestmarket), engine auto-adjusts via TIMEZONE_PRESETS
SESSION = {
    "london_start": 8,    # 08:00 UTC = 02:00 CT
    "london_end":   14,   # 14:00 UTC = 08:00 CT
    "ny_open_h":    14,
    "ny_open_m":    30,   # NY open: 14:30 UTC
    "ny_delay_min": 15,   # Skip first 15min of NY open ← KEY FIX (March 2026)
    "ny_close_h":   21,   # 21:00 UTC = 15:00 CT
}

# ── FILTERS ─────────────────────────────────────────────────────────────────
FILTERS = {
    "min_range":        100,   # pips — skip choppy days
    "max_range":        400,   # pips — skip news/high-vol days
    "regime_filter":    500,   # pips — skip day if 5d avg range > this ← KEY FIX
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
    "cp1_pips":   40,    # +40p: move T1+T2 SL to entry (breakeven)
    "cp2_pips":   80,    # +80p: close T1 at profit
    "cp3_pips":  120,    # +120p: trail T2 SL → entry+80p
    "cp4_pips":  250,    # +250p: close T2 (full target, 1:2.5 R/R)
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
