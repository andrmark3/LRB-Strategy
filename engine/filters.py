"""
LRB Strategy — Filters
All filter logic as pure functions. Easy to test, easy to tune.

Key fixes vs V1:
  - regime_filter  : skips hostile volatility months (March 2026 avg 433-640p → 0 losses)
  - trend_filter   : requires 10 prior closes (not 3), clamps pos to 0-1
  - get_ny_entry_start_min: 15min delay eliminated ALL March 2026 SL hits
"""
from datetime import date as Date
from config import FILTERS, SESSION


def range_filter(range_pips: float, cfg: dict = None) -> tuple[bool, str]:
    """Filter by London session range size."""
    c = cfg or FILTERS
    if range_pips < c["min_range"]:
        return False, f"range {range_pips:.0f}p < min {c['min_range']}p (choppy)"
    if range_pips > c["max_range"]:
        return False, f"range {range_pips:.0f}p > max {c['max_range']}p (news day)"
    return True, f"range {range_pips:.0f}p OK"


def regime_filter(date: Date, sorted_dates: list, day_ranges: dict,
                  cfg: dict = None) -> tuple[bool, str]:
    """
    Skip day if 5-day rolling avg London range > threshold.
    March 2026: avg was 433-640p. At 500p threshold, trading was blocked
    after Mar 5, converting -$180 loss into flat.
    """
    c = cfg or FILTERS
    idx = sorted_dates.index(date)
    prev = [d for d in sorted_dates[max(0, idx - c["regime_lookback"]):idx] if d.weekday() < 5]
    ranges = [day_ranges.get(d, 0) for d in prev if day_ranges.get(d, 0) > 0]
    if len(ranges) < 2:
        return True, "regime: not enough history"
    avg = sum(ranges) / len(ranges)
    if avg > c["regime_filter"]:
        return False, f"regime: 5d avg {avg:.0f}p > {c['regime_filter']}p"
    return True, f"regime: 5d avg {avg:.0f}p OK"


def trend_filter(date: Date, sorted_dates: list, daily_closes: dict,
                 cfg: dict = None) -> tuple[str, str]:
    """
    20-day high/low position ratio → trend direction.
    Returns ('UP' | 'DOWN' | 'FLAT', reason).
    Position clamped 0-1 to handle new-low/new-high days cleanly.
    Requires min 10 prior closes for reliability.
    """
    c = cfg or FILTERS
    idx = sorted_dates.index(date)
    if idx < 3:
        return "FLAT", "trend: too early (<3 days)"
    closes = [daily_closes[d] for d in sorted_dates[max(0, idx - c["trend_lb"]):idx]
              if d in daily_closes]
    if len(closes) < c["trend_min_closes"]:
        return "FLAT", f"trend: only {len(closes)} closes (need {c['trend_min_closes']})"
    hi, lo = max(closes), min(closes)
    rng = hi - lo
    if rng < 1:
        return "FLAT", "trend: 20d range too narrow"
    pos = max(0.0, min(1.0, (daily_closes.get(date, lo) - lo) / rng))
    if pos > c["trend_up_pos"]:  return "UP",   f"trend: UP  (pos={pos:.2f})"
    if pos < c["trend_dn_pos"]:  return "DOWN", f"trend: DOWN (pos={pos:.2f})"
    return "FLAT", f"trend: FLAT (pos={pos:.2f})"


class SweepDetector:
    """
    Liquidity sweep state machine.
    Phase 1: fake break — wick beyond range, close back inside.
    Phase 2: count confirmation closes beyond range for entry.
    """
    def __init__(self, rh, rl, allowed, confirm_bars=1):
        self.rh, self.rl = rh, rl
        self.allowed = allowed
        self.confirm = confirm_bars
        self.liq_bull = self.liq_bear = False
        self.sweep_idx = -1
        self.bull_cnt = self.bear_cnt = 0

    def update(self, bar_idx: int, bar: dict):
        if not self.liq_bull and bar["h"] > self.rh and bar["c"] <= self.rh:
            self.liq_bull = True; self.sweep_idx = bar_idx
        if not self.liq_bear and bar["l"] < self.rl and bar["c"] >= self.rl:
            self.liq_bear = True; self.sweep_idx = bar_idx

        can_buy  = self.liq_bull and self.allowed != "SELL"
        can_sell = self.liq_bear and self.allowed != "BUY"
        if (not can_buy and not can_sell) or bar_idx <= self.sweep_idx:
            return None

        if   bar["c"] > self.rh: self.bull_cnt += 1; self.bear_cnt = 0
        elif bar["c"] < self.rl: self.bear_cnt += 1; self.bull_cnt = 0
        else: self.bull_cnt = self.bear_cnt = 0

        if self.bull_cnt >= self.confirm and can_buy:  return ("BUY",  bar)
        if self.bear_cnt >= self.confirm and can_sell: return ("SELL", bar)
        return None


def get_ny_entry_start_min(cfg_session: dict = None) -> int:
    """Minutes from midnight at which entries are allowed. Includes NY delay."""
    c = cfg_session or SESSION
    return c["ny_open_h"] * 60 + c["ny_open_m"] + c.get("ny_delay_min", 0)


def ftmo_daily_guard(day_start_eq, current_eq, proposed_pnl,
                     account_start, max_daily_pct) -> tuple[bool, str]:
    loss = day_start_eq - (current_eq + proposed_pnl)
    if loss / account_start > max_daily_pct / 100:
        return False, f"FTMO daily guard: {loss:.0f}$ > {max_daily_pct}%"
    return True, "OK"


def ftmo_max_dd_check(peak_eq, current_eq, account_start, max_dd_pct) -> tuple[bool, str]:
    dd = (peak_eq - current_eq) / peak_eq * 100 if peak_eq > current_eq else 0
    if dd >= max_dd_pct:
        return False, f"Max DD {dd:.1f}% >= {max_dd_pct}% — trading halted"
    return True, f"DD {dd:.1f}% OK"
