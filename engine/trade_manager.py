"""
LRB Strategy — Trade Manager
T1 + T2 dual-position checkpoint management.
Mirrors exactly what the MT5 EA executes.

Checkpoints:
  CP1 (+40p):  move both SLs to entry (breakeven)
  CP2 (+100p): close T1; T2 SL → entry+40p
  CP3 (+120p): T2 SL → entry+100p
  CP4 (+350p): close T2 — full 1:3.5 R/R
Combined exit = average of T1 result + T2 result.

SL behaviors:
  Hard SL hit (no CPs)     → ep = -100p, outcome = loss
  BE stop (CP1, no CP2)    → ep = 0p,    outcome = be
  CP4 full target           → ep = (100+350)/2 = 225p, outcome = win
  Session close (no stop)  → ep = last_bar_close - entry
"""
from dataclasses import dataclass
from config import TRADE


@dataclass
class TradeResult:
    direction: str
    entry_price: float
    entry_time: object
    exit_pips: float = 0.0
    exit_reason: str = "open"
    t1_closed: bool = False
    t1_pips: float = 0.0
    cp1_hit: bool = False
    final_sl: float = 0.0

    @property
    def outcome(self) -> str:
        if self.exit_pips > 0.5:  return "win"
        if self.exit_pips < -0.5: return "loss"
        return "be"

    @property
    def pnl_r(self) -> float:
        return self.exit_pips / TRADE["sl_pips"]


def run_trade(entry_bar: dict, direction: str,
             remaining_bars: list[dict], cfg: dict = None) -> TradeResult:
    c   = cfg or TRADE
    adj = c["spread"] + c["slippage"]
    en  = entry_bar["c"] + (adj if direction == "BUY" else -adj)
    t2_sl = en - c["sl_pips"] if direction == "BUY" else en + c["sl_pips"]

    r = TradeResult(direction=direction, entry_price=en,
                    entry_time=entry_bar["dt"], final_sl=t2_sl)

    def p(price): return (price - en) if direction == "BUY" else (en - price)

    for bar in remaining_bars:
        sl_hit = bar["l"] <= t2_sl if direction == "BUY" else bar["h"] >= t2_sl
        if sl_hit:
            raw = p(t2_sl)
            r.exit_pips   = (r.t1_pips + raw) / 2 if r.t1_closed else raw
            r.exit_reason = "BE stop" if r.cp1_hit else "SL hit"
            r.final_sl    = t2_sl
            return r

        pips = p(bar["c"])

        if pips >= c["cp1_pips"] and not r.cp1_hit:
            r.cp1_hit = True
            t2_sl = en

        if pips >= c["cp2_pips"] and not r.t1_closed:
            r.t1_closed = True
            r.t1_pips   = c["cp2_pips"]
            t2_sl = en + c["cp1_pips"] if direction == "BUY" else en - c["cp1_pips"]

        if pips >= c["cp3_pips"] and r.t1_closed:
            new_sl = en + c["cp2_pips"] if direction == "BUY" else en - c["cp2_pips"]
            if (direction == "BUY" and new_sl > t2_sl) or (direction == "SELL" and new_sl < t2_sl):
                t2_sl = new_sl

        if pips >= c["cp4_pips"]:
            r.exit_pips   = (r.t1_pips + c["cp4_pips"]) / 2 if r.t1_closed else c["cp4_pips"]
            r.exit_reason = "CP4 full target"
            return r

    if remaining_bars:
        last_p = p(remaining_bars[-1]["c"])
        r.exit_pips   = (r.t1_pips + last_p) / 2 if r.t1_closed else last_p
        r.exit_reason = "session close"
    return r


def calc_pnl(result: TradeResult, equity: float, risk_pct: float, sl_pips: float) -> float:
    return result.exit_pips * (equity * risk_pct / 100) / sl_pips
