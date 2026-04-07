//+------------------------------------------------------------------+
//| LRB_V2_EA.mq5 — London Range Breakout V2                        |
//| Semi-automated: detects setup, alerts human, manages trade       |
//| Logic mirrors engine/filters.py + engine/trade_manager.py       |
//+------------------------------------------------------------------+
#property copyright "LRB Strategy"
#property version   "2.0.1"
#property strict

#include "LRB_V2_EA.mqh"

//--- Input Parameters (mirror config.py exactly)
input group "=== SESSION HOURS (broker UTC) ==="
input int    LON_START_H      = 8;
input int    LON_END_H        = 14;
input int    NY_OPEN_H        = 14;
input int    NY_OPEN_M        = 30;
input int    NY_DELAY_MIN     = 15;   // Skip first 15min — KEY FIX
input int    NY_CLOSE_H       = 21;

input group "=== FILTERS ==="
input int    MIN_RANGE        = 100;
input int    MAX_RANGE        = 400;
input int    REGIME_THRESHOLD = 500;  // 5d avg range filter — KEY FIX
input int    REGIME_LOOKBACK  = 5;
input int    TREND_LB         = 20;
input int    TREND_MIN_CLOSES = 10;   // min closes before trusting trend — KEY FIX
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
input int    CONFIRM_TIMEOUT  = 2;    // bars to wait for human confirm
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
   ResetDay();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick() {
   datetime now = TimeCurrent();
   MqlDateTime t; TimeToStruct(now, t);

   // New day reset at London open
   if(t.hour == LON_START_H && t.min == 0 && t.sec < 5) ResetDay();

   int bar = iBars(_Symbol, PERIOD_M1) - 1;
   if(bar == g_bars_seen) return;
   g_bars_seen = bar;

   switch(g_state) {
      case IDLE:           OnIdle(t);          break;
      case WAITING_SWEEP:  OnWaitingSweep(t);  break;
      case WAITING_HUMAN:  OnWaitingHuman(t);  break;
      case WAITING_CONFIRM:if(HasPositions()) g_state=MANAGING; break;
      case MANAGING:       ManageTrades(t);    break;
   }
}

//+------------------------------------------------------------------+
void OnIdle(MqlDateTime &t) {
   // Build London range during London session
   if(IsLondon(t) && g_rh == 0) BuildRange();
   // At London close, check all filters
   if(t.hour == LON_END_H && t.min == 0 && g_rh > 0)
      g_state = CheckFilters() ? WAITING_SWEEP : IDLE;
}

//+------------------------------------------------------------------+
bool CheckFilters() {
   double rng = (g_rh - g_rl) / _Point / PIP_FACTOR;
   if(rng < MIN_RANGE || rng > MAX_RANGE) {
      Print("SKIP: range ", rng, "p"); return false;
   }
   double avg5 = CalcRegimeAvg();
   if(avg5 > REGIME_THRESHOLD) {
      Print("SKIP: regime ", avg5, "p > ", REGIME_THRESHOLD, "p"); return false;
   }
   g_direction = CalcTrend();
   if(g_direction == "FLAT") {
      Print("SKIP: trend FLAT"); return false;
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd  = (g_day_start - bal) / g_day_start * 100;
   if(dd > FTMO_MAX_DD) {
      Print("SKIP: max DD breached"); return false;
   }
   Print("Filters OK — direction:", g_direction, " range:", rng, "p");
   return true;
}

//+------------------------------------------------------------------+
void OnWaitingSweep(MqlDateTime &t) {
   if(!IsNY(t) || !IsBeforeClose(t)) return;

   double hi = iHigh(_Symbol, PERIOD_M1, 0);
   double lo = iLow(_Symbol, PERIOD_M1, 0);
   double cl = iClose(_Symbol, PERIOD_M1, 0);

   // Phase 1: detect sweep
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

   // Phase 2: count confirmation bars
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

   // CP1: breakeven
   if(pips >= CP1_PIPS && !g_cp1_hit) {
      g_cp1_hit = true; g_t2_sl = g_entry;
      MoveAllSL(g_entry); Print("CP1: moved to breakeven");
   }
   // CP2: close T1
   if(pips >= CP2_PIPS && !g_t1_closed) {
      g_t1_closed = true; CloseT1();
      double new_sl = g_direction=="BUY" ? g_entry + CP1_PIPS*_Point*PIP_FACTOR
                                         : g_entry - CP1_PIPS*_Point*PIP_FACTOR;
      g_t2_sl = new_sl; MoveT2SL(new_sl); Print("CP2: T1 closed");
   }
   // CP3: trail T2
   if(pips >= CP3_PIPS && g_t1_closed) {
      double trail = g_direction=="BUY" ? g_entry + CP2_PIPS*_Point*PIP_FACTOR
                                        : g_entry - CP2_PIPS*_Point*PIP_FACTOR;
      if((g_direction=="BUY" && trail > g_t2_sl) || (g_direction=="SELL" && trail < g_t2_sl)) {
         g_t2_sl = trail; MoveT2SL(trail); Print("CP3: T2 trailed to entry+80p");
      }
   }
   // CP4: full target
   if(pips >= CP4_PIPS) {
      CloseAll(); Print("CP4: full target hit — trade complete"); g_state=IDLE; return;
   }
   // Session close
   if(t.hour >= NY_CLOSE_H) {
      CloseAll(); Print("Session close — exit"); g_state=IDLE; return;
   }
   // FTMO daily guard
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if((g_day_start - bal) / g_day_start * 100 > FTMO_DAILY_GUARD) {
      CloseAll(); SendNotification("⚠ LRB V2: FTMO daily guard — trading paused");
      g_state = IDLE;
   }
}

//+------------------------------------------------------------------+
void SendAlert(double price, string dir) {
   double sl  = dir=="BUY" ? price - SL_PIPS*_Point*PIP_FACTOR : price + SL_PIPS*_Point*PIP_FACTOR;
   double cp4 = dir=="BUY" ? price + CP4_PIPS*_Point*PIP_FACTOR : price - CP4_PIPS*_Point*PIP_FACTOR;
   double rng = (g_rh - g_rl) / _Point / PIP_FACTOR;
   string msg = StringFormat(
      "🔔 LRB V2 SETUP\nDir: %s | Range: %.0f-%.0f (%.0fp)\nTrend: %s | Sweep: ✓\n"
      "Entry: ~%.1f | SL: %.1f | CP4: %.1f\nRisk: %.1f%%/leg | Confirm within %d bar(s)",
      dir, g_rl, g_rh, rng, g_direction, price, sl, cp4, RISK_PCT_LEG, CONFIRM_TIMEOUT);
   SendNotification(msg); Alert(msg);
}

//+------------------------------------------------------------------+
void BuildRange() {
   g_rh = 0; g_rl = DBL_MAX;
   int total = iBars(_Symbol, PERIOD_M1);
   for(int i = 0; i < total; i++) {
      MqlDateTime bt; TimeToStruct(iTime(_Symbol, PERIOD_M1, i), bt);
      if(bt.hour < LON_START_H || bt.hour >= LON_END_H) continue;
      g_rh = MathMax(g_rh, iHigh(_Symbol, PERIOD_M1, i));
      g_rl = MathMin(g_rl, iLow(_Symbol, PERIOD_M1, i));
   }
   if(g_rh == 0) g_rl = 0;
   else Print("London range: ", g_rl, " - ", g_rh, " (", (g_rh-g_rl)/_Point/PIP_FACTOR, "p)");
}

double CalcRegimeAvg() {
   double sum = 0; int cnt = 0;
   for(int d = 1; d <= REGIME_LOOKBACK; d++) {
      sum += (iHigh(_Symbol,PERIOD_D1,d) - iLow(_Symbol,PERIOD_D1,d)) / _Point / PIP_FACTOR;
      cnt++;
   }
   return cnt > 0 ? sum/cnt : 0;
}

string CalcTrend() {
   double hi = 0, lo = DBL_MAX;
   int valid = 0;
   for(int d = 1; d <= TREND_LB; d++) {
      hi = MathMax(hi, iHigh(_Symbol, PERIOD_D1, d));
      lo = MathMin(lo, iLow(_Symbol,  PERIOD_D1, d));
      valid++;
   }
   if(valid < TREND_MIN_CLOSES) return "FLAT";
   double rng = hi - lo;
   if(rng < _Point) return "FLAT";
   double cur = iClose(_Symbol, PERIOD_D1, 1);
   double pos = MathMax(0, MathMin(1, (cur - lo) / rng));
   if(pos > TREND_UP_POS) return "BUY";
   if(pos < TREND_DN_POS) return "SELL";
   return "FLAT";
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
   g_entry = price;
   g_t2_sl = sl;
}

bool IsLondon(MqlDateTime &t) { return t.hour >= LON_START_H && t.hour < LON_END_H; }
bool IsNY(MqlDateTime &t) {
   int m = t.hour*60 + t.min;
   return m >= NY_OPEN_H*60 + NY_OPEN_M + NY_DELAY_MIN;
}
bool IsBeforeClose(MqlDateTime &t) { return t.hour < NY_CLOSE_H; }
bool HasPositions() { return PositionsTotal() > 0; }

void MoveAllSL(double sl) {
   for(int i = 0; i < PositionsTotal(); i++)
      trade.PositionModify(PositionGetTicket(i), sl, 0);
}
void MoveT2SL(double sl) {
   if(g_t2 > 0 && PositionSelectByTicket(g_t2))
      trade.PositionModify(g_t2, sl, 0);
}
void CloseT1() { if(g_t1 > 0) trade.PositionClose(g_t1); }
void CloseAll() {
   for(int i = PositionsTotal()-1; i >= 0; i--)
      trade.PositionClose(PositionGetTicket(i));
}
void ResetDay() {
   g_state=IDLE; g_rh=0; g_rl=0; g_direction="";
   g_sweep_bar=-1; g_confirm_cnt=0; g_bull_sweep=false; g_bear_sweep=false;
   g_t1=0; g_t2=0; g_cp1_hit=false; g_t1_closed=false; g_bars_seen=0;
   g_day_start = AccountInfoDouble(ACCOUNT_BALANCE);
}
