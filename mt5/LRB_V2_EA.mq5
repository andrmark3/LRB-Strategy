//+------------------------------------------------------------------+
//| LRB_V2_EA.mq5 — London Range Breakout V2                        |
//| Semi-automated: detects setup, alerts human, manages trade       |
//| Logic mirrors engine/filters.py + engine/trade_manager.py       |
//+------------------------------------------------------------------+
#property copyright "LRB Strategy"
#property version   "2.0.2"
#property strict

#include "LRB_V2_EA.mqh"

//--- Input Parameters (mirror config.py exactly)
input group "=== SESSION HOURS (broker UTC) ==="
input int    LON_START_H      = 8;
input int    LON_END_H        = 14;
input int    NY_OPEN_H        = 14;
input int    NY_OPEN_M        = 30;
input int    NY_DELAY_MIN     = 15;   // Skip first 15min of NY open — KEY FIX
input int    NY_CLOSE_H       = 21;

input group "=== FILTERS ==="
input int    MIN_RANGE        = 100;
input int    MAX_RANGE        = 400;
input int    REGIME_THRESHOLD = 500;  // 5d avg London range filter — KEY FIX
input int    REGIME_LOOKBACK  = 5;    // trading days
input int    TREND_LB         = 20;   // trading days
input int    TREND_MIN_CLOSES = 10;   // min daily closes before trusting trend — KEY FIX
input double TREND_UP_POS     = 0.60;
input double TREND_DN_POS     = 0.40;
input int    CONFIRM_BARS     = 1;
input bool   REQUIRE_SWEEP    = true;

input group "=== TRADE MANAGEMENT ==="
input int    SL_PIPS          = 100;
input int    CP1_PIPS         = 40;
input int    CP2_PIPS         = 80;
input int    CP3_PIPS         = 120;
input int    CP4_PIPS         = 250;
input int    SPREAD_PIPS      = 2;
input int    SLIP_PIPS        = 1;

input group "=== RISK ==="
input double RISK_PCT_LEG     = 0.5;   // Phase 1: 1.0% | Phase 2: 0.5%
input double FTMO_DAILY_GUARD = 4.0;
input double FTMO_MAX_DD      = 8.0;

input group "=== SEMI-AUTO ==="
input bool   SEMI_AUTO        = true;
input int    CONFIRM_TIMEOUT  = 2;
input string MAGIC_COMMENT    = "LRB_V2";

//--- EA State Machine
enum EAState { IDLE, WAITING_SWEEP, WAITING_CONFIRM, WAITING_HUMAN, MANAGING };

EAState g_state       = IDLE;
double  g_rh          = 0, g_rl = 0;
string  g_direction   = "";
int     g_sweep_bar   = -1, g_confirm_cnt = 0, g_alert_bar = -1;
bool    g_bull_sweep  = false, g_bear_sweep = false;
ulong   g_t1          = 0, g_t2 = 0;
bool    g_cp1_hit     = false, g_t1_closed = false;
double  g_entry       = 0, g_t2_sl = 0;
double  g_day_start   = 0;
int     g_bars_seen   = 0;
CTrade  trade;

//+------------------------------------------------------------------+
int OnInit() {
   Print("LRB V2 EA v", EA_VERSION, " — ", SEMI_AUTO ? "SEMI-AUTO" : "FULLY AUTO");
   Print("Regime filter uses M1 London bars (08:00-14:00 UTC) — exact match to Python engine");
   ResetDay();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick() {
   datetime now = TimeCurrent();
   MqlDateTime t; TimeToStruct(now, t);

   if(t.hour == LON_START_H && t.min == 0 && t.sec < 5) ResetDay();

   int bar = iBars(_Symbol, PERIOD_M1) - 1;
   if(bar == g_bars_seen) return;
   g_bars_seen = bar;

   switch(g_state) {
      case IDLE:            OnIdle(t);          break;
      case WAITING_SWEEP:   OnWaitingSweep(t);  break;
      case WAITING_HUMAN:   OnWaitingHuman(t);  break;
      case WAITING_CONFIRM: if(HasPositions()) g_state=MANAGING; break;
      case MANAGING:        ManageTrades(t);    break;
   }
}

//+------------------------------------------------------------------+
void OnIdle(MqlDateTime &t) {
   if(IsLondon(t) && g_rh == 0) BuildRange();
   if(t.hour == LON_END_H && t.min == 0 && g_rh > 0)
      g_state = CheckFilters() ? WAITING_SWEEP : IDLE;
}

//+------------------------------------------------------------------+
bool CheckFilters() {
   double rng = (g_rh - g_rl) / _Point / PIP_FACTOR;
   if(rng < MIN_RANGE || rng > MAX_RANGE) {
      Print("SKIP: range ", rng, "p"); return false;
   }

   double avg5 = CalcRegimeAvgM1();  // FIX: now uses M1 London bars, not D1
   if(avg5 > REGIME_THRESHOLD) {
      Print("SKIP: regime 5d avg ", avg5, "p > ", REGIME_THRESHOLD, "p"); return false;
   }

   g_direction = CalcTrendFromDailyCloses();  // FIX: uses M1-derived daily closes
   if(g_direction == "FLAT") {
      Print("SKIP: trend FLAT"); return false;
   }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if((g_day_start - bal) / g_day_start * 100 > FTMO_MAX_DD) {
      Print("SKIP: max DD breached"); return false;
   }

   Print("Filters OK — direction:", g_direction, " range:", rng, "p avg5:", avg5, "p");
   return true;
}

//+------------------------------------------------------------------+
//| FIXED: CalcRegimeAvgM1                                           |
//| Uses M1 bars filtered to London hours (LON_START_H–LON_END_H).  |
//| Matches Python engine exactly:                                   |
//|   lon = [b for b in db if sess["london_start"] <= b.hour < end] |
//|   day_ranges[d] = max(h) - min(l)                               |
//+------------------------------------------------------------------+
double CalcRegimeAvgM1() {
   double daily_ranges[];
   ArraySetAsSeries(daily_ranges, true);
   int days_found = 0;

   // Walk back through M1 bars, grouping by trading day
   int total_m1 = iBars(_Symbol, PERIOD_M1);
   string cur_day = "";
   double day_hi = 0, day_lo = DBL_MAX;
   bool day_has_london = false;

   for(int i = 0; i < total_m1 && days_found < REGIME_LOOKBACK; i++) {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime bt; TimeToStruct(bar_time, bt);
      string day_str = StringFormat("%04d.%02d.%02d", bt.year, bt.mon, bt.day);

      // Day boundary
      if(day_str != cur_day) {
         // Save previous day if it had London bars
         if(cur_day != "" && day_has_london) {
            ArrayResize(daily_ranges, days_found + 1);
            daily_ranges[days_found] = (day_hi - day_lo) / _Point / PIP_FACTOR;
            days_found++;
         }
         // Skip weekends
         if(bt.day_of_week == 0 || bt.day_of_week == 6) { cur_day = day_str; continue; }
         cur_day = day_str;
         day_hi = 0; day_lo = DBL_MAX; day_has_london = false;
      }

      // Only include London session bars
      if(bt.hour >= LON_START_H && bt.hour < LON_END_H) {
         day_hi = MathMax(day_hi, iHigh(_Symbol, PERIOD_M1, i));
         day_lo = MathMin(day_lo, iLow(_Symbol,  PERIOD_M1, i));
         day_has_london = true;
      }
   }

   if(days_found < 2) return 0;

   double sum = 0;
   for(int i = 0; i < days_found; i++) sum += daily_ranges[i];
   return sum / days_found;
}

//+------------------------------------------------------------------+
//| FIXED: CalcTrendFromDailyCloses                                  |
//| Uses M1 bar daily close prices (last M1 bar of each day).       |
//| Matches Python engine:                                           |
//|   dc = {d: day_bars[-1]['c'] for d in sorted_dates}             |
//|   pos = (cur_close - lo20) / (hi20 - lo20)  clamped 0-1        |
//+------------------------------------------------------------------+
string CalcTrendFromDailyCloses() {
   double daily_closes[];
   int days_found = 0;

   int total_m1 = iBars(_Symbol, PERIOD_M1);
   string cur_day = "";
   double last_close = 0;

   for(int i = 0; i < total_m1; i++) {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime bt; TimeToStruct(bar_time, bt);
      if(bt.day_of_week == 0 || bt.day_of_week == 6) continue;
      string day_str = StringFormat("%04d.%02d.%02d", bt.year, bt.mon, bt.day);

      if(day_str != cur_day) {
         // New day: save the close of the previous day (last bar = earliest in series)
         if(cur_day != "" && last_close > 0) {
            ArrayResize(daily_closes, days_found + 1);
            daily_closes[days_found] = last_close;
            days_found++;
            if(days_found > TREND_LB + 1) break;  // got enough
         }
         cur_day = day_str;
      }
      last_close = iClose(_Symbol, PERIOD_M1, i);  // last bar seen for this day = earliest M1
   }

   if(days_found < TREND_MIN_CLOSES) return "FLAT";

   // Use last TREND_LB days as lookback (skip index 0 = today)
   int start = 1;  // skip today
   int end   = MathMin(days_found, TREND_LB + 1);

   double hi = 0, lo = DBL_MAX;
   for(int i = start; i < end; i++) {
      hi = MathMax(hi, daily_closes[i]);
      lo = MathMin(lo, daily_closes[i]);
   }

   double rng = hi - lo;
   if(rng < _Point) return "FLAT";

   // Today's close = close of the most recent complete day (index 1 in series = yesterday)
   double today_close = daily_closes[0] > 0 ? daily_closes[0] : daily_closes[1];
   double pos = MathMax(0, MathMin(1, (today_close - lo) / rng));

   if(pos > TREND_UP_POS) return "BUY";
   if(pos < TREND_DN_POS) return "SELL";
   return "FLAT";
}

//+------------------------------------------------------------------+
void OnWaitingSweep(MqlDateTime &t) {
   if(!IsNY(t) || !IsBeforeClose(t)) return;

   double hi = iHigh(_Symbol, PERIOD_M1, 0);
   double lo = iLow(_Symbol, PERIOD_M1, 0);
   double cl = iClose(_Symbol, PERIOD_M1, 0);

   if(!g_bull_sweep && hi > g_rh && cl <= g_rh) {
      g_bull_sweep = true; g_sweep_bar = g_bars_seen;
      Print("BULL sweep at ", TimeToString(TimeCurrent()));
   }
   if(!g_bear_sweep && lo < g_rl && cl >= g_rl) {
      g_bear_sweep = true; g_sweep_bar = g_bars_seen;
      Print("BEAR sweep at ", TimeToString(TimeCurrent()));
   }

   bool can_buy  = g_bull_sweep && g_direction != "SELL";
   bool can_sell = g_bear_sweep && g_direction != "BUY";
   if((!can_buy && !can_sell) || g_bars_seen <= g_sweep_bar) return;

   if(can_buy  && cl > g_rh) g_confirm_cnt++;
   else if(can_sell && cl < g_rl) g_confirm_cnt++;
   else g_confirm_cnt = 0;

   if(g_confirm_cnt >= CONFIRM_BARS) {
      double price = SymbolInfoDouble(_Symbol, can_buy ? SYMBOL_ASK : SYMBOL_BID);
      SendAlert(price, can_buy ? "BUY" : "SELL");
      g_alert_bar = g_bars_seen;
      if(SEMI_AUTO) {
         g_state = WAITING_HUMAN;
      } else {
         ExecuteEntry(price, can_buy ? "BUY" : "SELL");
         g_state = WAITING_CONFIRM;
      }
   }
}

//+------------------------------------------------------------------+
void OnWaitingHuman(MqlDateTime &t) {
   if(CONFIRM_TIMEOUT > 0 && g_bars_seen > g_alert_bar + CONFIRM_TIMEOUT) {
      Print("Setup cancelled — no confirm in ", CONFIRM_TIMEOUT, " bars");
      g_state = IDLE; return;
   }
   if(HasPositions()) {
      g_entry    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_t2_sl    = g_direction=="BUY" ? g_entry - SL_PIPS*_Point*PIP_FACTOR
                                      : g_entry + SL_PIPS*_Point*PIP_FACTOR;
      g_cp1_hit  = false; g_t1_closed = false;
      g_state    = MANAGING;
      Print("Human confirmed — managing trade. Entry:", g_entry);
   }
}

//+------------------------------------------------------------------+
void ManageTrades(MqlDateTime &t) {
   if(!HasPositions() && g_t1_closed) { g_state=IDLE; return; }

   double cur  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pips = (g_direction=="BUY" ? cur - g_entry : g_entry - cur) / _Point / PIP_FACTOR;

   if(pips >= CP1_PIPS && !g_cp1_hit) {
      g_cp1_hit = true; g_t2_sl = g_entry;
      MoveAllSL(g_entry); Print("CP1: moved to breakeven");
   }
   if(pips >= CP2_PIPS && !g_t1_closed) {
      g_t1_closed = true; CloseT1();
      double new_sl = g_direction=="BUY" ? g_entry + CP1_PIPS*_Point*PIP_FACTOR
                                         : g_entry - CP1_PIPS*_Point*PIP_FACTOR;
      g_t2_sl = new_sl; MoveT2SL(new_sl); Print("CP2: T1 closed at +", CP2_PIPS, "p");
   }
   if(pips >= CP3_PIPS && g_t1_closed) {
      double trail = g_direction=="BUY" ? g_entry + CP2_PIPS*_Point*PIP_FACTOR
                                        : g_entry - CP2_PIPS*_Point*PIP_FACTOR;
      if((g_direction=="BUY" && trail > g_t2_sl) || (g_direction=="SELL" && trail < g_t2_sl)) {
         g_t2_sl = trail; MoveT2SL(trail); Print("CP3: T2 SL trailed to entry+", CP2_PIPS, "p");
      }
   }
   if(pips >= CP4_PIPS) {
      CloseAll(); Print("CP4: full target +", CP4_PIPS, "p — trade complete"); g_state=IDLE; return;
   }
   if(t.hour >= NY_CLOSE_H) {
      CloseAll(); Print("Session close — all positions closed"); g_state=IDLE; return;
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if((g_day_start - bal) / g_day_start * 100 > FTMO_DAILY_GUARD) {
      CloseAll(); SendNotification("⚠ LRB V2: FTMO daily guard triggered");
      Print("FTMO daily guard — trading paused for today"); g_state = IDLE;
   }
}

//+------------------------------------------------------------------+
void SendAlert(double price, string dir) {
   double sl  = dir=="BUY" ? price - SL_PIPS*_Point*PIP_FACTOR : price + SL_PIPS*_Point*PIP_FACTOR;
   double cp4 = dir=="BUY" ? price + CP4_PIPS*_Point*PIP_FACTOR : price - CP4_PIPS*_Point*PIP_FACTOR;
   double rng = (g_rh - g_rl) / _Point / PIP_FACTOR;
   string msg = StringFormat(
      "🔔 LRB V2 SETUP\nDir: %s | Range: %.0f-%.0f (%.0fp)\nTrend: %s | Sweep: ✓\n"
      "Entry: ~%.1f | SL: %.1f | CP4: %.1f\n"
      "Risk: %.1f%%/leg (%.1f%% total)\n"
      "Confirm within %d bar(s)",
      dir, g_rl, g_rh, rng, g_direction, price, sl, cp4,
      RISK_PCT_LEG, RISK_PCT_LEG*2, CONFIRM_TIMEOUT);
   SendNotification(msg); Alert(msg);
}

//+------------------------------------------------------------------+
void BuildRange() {
   g_rh = 0; g_rl = DBL_MAX;
   int total = iBars(_Symbol, PERIOD_M1);
   for(int i = 0; i < total; i++) {
      datetime bar_time = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime bt; TimeToStruct(bar_time, bt);
      // Only today's London bars
      MqlDateTime now_t; TimeToStruct(TimeCurrent(), now_t);
      if(bt.year != now_t.year || bt.mon != now_t.mon || bt.day != now_t.day) break;
      if(bt.hour < LON_START_H || bt.hour >= LON_END_H) continue;
      g_rh = MathMax(g_rh, iHigh(_Symbol, PERIOD_M1, i));
      g_rl = MathMin(g_rl, iLow(_Symbol,  PERIOD_M1, i));
   }
   if(g_rh == 0) { g_rl = 0; return; }
   double rng_p = (g_rh - g_rl) / _Point / PIP_FACTOR;
   Print("London range built: ", g_rl, " - ", g_rh, " (", rng_p, "p)");
}

void ExecuteEntry(double price, string dir) {
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * RISK_PCT_LEG / 100.0;
   double pv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lots = NormalizeDouble(risk / (SL_PIPS * pv), 2);
   double sl   = dir=="BUY" ? price - SL_PIPS*_Point*PIP_FACTOR : price + SL_PIPS*_Point*PIP_FACTOR;
   for(int i = 0; i < 2; i++) {
      if(dir=="BUY") trade.Buy(lots,  _Symbol, price, sl, 0, MAGIC_COMMENT);
      else           trade.Sell(lots, _Symbol, price, sl, 0, MAGIC_COMMENT);
   }
   g_entry = price; g_t2_sl = sl;
   Print("Entered ", dir, " lots=", lots, " entry=", price, " SL=", sl);
}

bool IsLondon(MqlDateTime &t)     { return t.hour >= LON_START_H && t.hour < LON_END_H; }
bool IsNY(MqlDateTime &t)         { return (t.hour*60+t.min) >= NY_OPEN_H*60+NY_OPEN_M+NY_DELAY_MIN; }
bool IsBeforeClose(MqlDateTime &t){ return t.hour < NY_CLOSE_H; }
bool HasPositions()               { return PositionsTotal() > 0; }

void MoveAllSL(double sl) {
   for(int i = 0; i < PositionsTotal(); i++) trade.PositionModify(PositionGetTicket(i), sl, 0);
}
void MoveT2SL(double sl) {
   if(g_t2 > 0 && PositionSelectByTicket(g_t2)) trade.PositionModify(g_t2, sl, 0);
}
void CloseT1() { if(g_t1 > 0) trade.PositionClose(g_t1); }
void CloseAll() {
   for(int i = PositionsTotal()-1; i >= 0; i--) trade.PositionClose(PositionGetTicket(i));
}
void ResetDay() {
   g_state=IDLE; g_rh=0; g_rl=0; g_direction="";
   g_sweep_bar=-1; g_confirm_cnt=0; g_bull_sweep=false; g_bear_sweep=false;
   g_t1=0; g_t2=0; g_cp1_hit=false; g_t1_closed=false; g_bars_seen=0;
   g_day_start=AccountInfoDouble(ACCOUNT_BALANCE);
}
