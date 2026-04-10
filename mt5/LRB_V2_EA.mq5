//+------------------------------------------------------------------+
//| LRB_V2_EA.mq5 — London Range Breakout V2                        |
//| Semi-automated: detects setup, alerts human, manages trade       |
//| Logic mirrors engine/filters.py + engine/trade_manager.py       |
//| v2.4.0 — fix bar-index bugs causing zero trades in backtester    |
//|                                                                  |
//| HOW TO USE:                                                      |
//|   Strategy Tester : SEMI_AUTO can be true or false — the EA      |
//|                     auto-detects the tester and always enters.   |
//|   Live / Demo     : SEMI_AUTO = true  (human confirms entry)     |
//|                     SEMI_AUTO = false (fully automated)          |
//|                                                                  |
//| PIP_FACTOR: 1.0 for US30 — 1 pip = 1 price unit (1 Dow point)   |
//|   _Point is irrelevant; only PIP_FACTOR determines pip size.     |
//|   Override only if your broker uses fractional units (rare).     |
//+------------------------------------------------------------------+
#property copyright "LRB Strategy"
#property version   "2.40"
#property strict

#include <LRB/LRB_V2_EA.mqh>

//=== SESSION HOURS (all in UTC — adjust BROKER_UTC_OFFSET if needed) ===
input group "=== SESSION HOURS (UTC) ==="
input int    LON_START_H      = 8;    // London open  08:00 UTC
input int    LON_END_H        = 14;   // London close 14:00 UTC
input int    NY_OPEN_H        = 14;   // NY open      14:30 UTC
input int    NY_OPEN_M        = 30;
input int    NY_DELAY_MIN     = 15;   // Skip first 15 min of NY open (KEY FIX)
input int    NY_CLOSE_H       = 21;   // Force-exit   21:00 UTC
input int    BROKER_UTC_OFFSET= 0;    // Hours to add to convert UTC -> broker time

//=== FILTERS ===
input group "=== FILTERS (mirror config.py) ==="
input int    MIN_RANGE        = 100;  // pips — skip choppy days
input int    MAX_RANGE        = 400;  // pips — skip news/high-vol days
input int    REGIME_THRESHOLD = 400;  // pips — skip if 5d avg > this (KEY FIX)
input int    REGIME_LOOKBACK  = 5;    // trading days for rolling avg
input int    TREND_LB         = 20;   // trading days for 20d trend
input int    TREND_MIN_CLOSES = 10;   // min closes before trusting trend (KEY FIX)
input double TREND_UP_POS     = 0.60; // above 60% of 20d range = uptrend, BUY only
input double TREND_DN_POS     = 0.40; // below 40% of 20d range = downtrend, SELL only
input int    CONFIRM_BARS     = 1;    // bars beyond range after sweep to confirm
input bool   REQUIRE_SWEEP    = true; // require fake-break before entry

//=== TRADE MANAGEMENT ===
input group "=== TRADE MANAGEMENT (mirror config.py) ==="
input int    SL_PIPS          = 100;  // Stop loss
input int    CP1_PIPS         = 40;   // +40p: both SLs → breakeven
input int    CP2_PIPS         = 80;   // +80p: close T1
input int    CP3_PIPS         = 120;  // +120p: trail T2 SL → entry+80p
input int    CP4_PIPS         = 250;  // +250p: close T2 (full target 1:2.5)
input int    SPREAD_PIPS      = 2;    // typical US30 spread
input int    SLIP_PIPS        = 1;    // entry slippage estimate

//=== RISK MANAGEMENT ===
input group "=== RISK MANAGEMENT ==="
input double RISK_PCT_LEG     = 0.5;  // % of account per leg. FTMO Ph1=1.0, Ph2=0.5
input double FTMO_DAILY_GUARD = 4.0;  // halt if day loss > this %
input double FTMO_MAX_DD      = 8.0;  // halt if total DD > this %
input double PIP_FACTOR       = 1.0;  // 1 pip = PIP_FACTOR price units. 1.0 for US30 (1 Dow point). Broker _Point is irrelevant.

//=== MODE ===
input group "=== MODE ==="
input bool   SEMI_AUTO        = true; // true=wait for human confirm | false=auto (use for backtesting)
input int    CONFIRM_TIMEOUT  = 3;    // bars to wait for human confirmation

//=== CHART VISUALS ===
input group "=== CHART VISUALS ==="
input color  LON_BOX_COLOR    = clrCornflowerBlue; // London session box colour
input color  NY_BOX_COLOR     = clrSandyBrown;     // NY session box colour (orange)
input bool   DRAW_CP_LINES    = true;               // draw CP level lines on chart
input bool   DRAW_ENTRY_ARROW = true;               // draw entry arrow on chart

//--- State Machine
enum EAState { IDLE, WAITING_SWEEP, WAITING_HUMAN, MANAGING };

//--- Global State
EAState  g_state           = IDLE;
double   g_rh              = 0,    g_rl = 0;
string   g_direction       = "";
int      g_sweep_bar       = -1,   g_confirm_cnt = 0, g_alert_bar = -1;
bool     g_bull_sweep      = false, g_bear_sweep = false;
bool     g_cp1_hit         = false, g_t1_closed = false, g_cp3_hit = false;
double   g_entry           = 0,    g_t2_sl = 0;
double   g_day_start_eq    = 0;
int      g_bars_seen       = 0;
ulong    g_t1_ticket       = 0,    g_t2_ticket = 0;
datetime g_lon_start_dt    = 0;
datetime g_ny_start_dt     = 0;
bool     g_assessment_sent = false;
string   g_day_tag         = "";   // "YYYYMMDD" used as suffix for chart object names

CTrade trade;

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(30);
   Print("LRB V2 EA v", EA_VERSION, " loaded");
   Print("Symbol:", _Symbol, " _Point:", _Point, " PIP_FACTOR:", PIP_FACTOR,
         " → 1 pip = ", PIP_FACTOR, " price units (broker _Point not used)");
   Print("Mode: ", SEMI_AUTO ? "SEMI-AUTO (human confirms entry)" : "FULLY AUTO (use for backtesting)");
   ResetDay();
   // Rebuild today's range if we attach mid-session
   ScanTodayRange();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   // Chart objects intentionally persist after EA removal so you can review the day.
   // To wipe them: uncomment the line below.
   // ObjectsDeleteAll(0, "LRB_");
}

//+------------------------------------------------------------------+
void OnTick() {
   datetime now = TimeCurrent();
   MqlDateTime t; TimeToStruct(now, t);

   // Adjust to UTC if broker is offset
   int utc_hour = ((t.hour - BROKER_UTC_OFFSET) % 24 + 24) % 24;
   t.hour = utc_hour;

   // Day reset at London open
   if(t.hour == LON_START_H && t.min == 0 && t.sec < 5
      && t.day_of_week > 0 && t.day_of_week < 6)
      ResetDay();

   // Bar-level: only process on a new M1 close
   int cur_bars = iBars(_Symbol, PERIOD_M1);
   if(cur_bars == g_bars_seen) return;
   g_bars_seen = cur_bars;

   // Continuously update London range and box while London is open.
   // Extend to <= LON_END_H so the 14:00 bar-open event captures the
   // just-completed 13:59 bar (the last London bar).  UpdateLondonRange()
   // internally verifies that bar[1] actually falls within London hours.
   if(t.hour >= LON_START_H && t.hour <= LON_END_H
      && t.day_of_week > 0 && t.day_of_week < 6)
      UpdateLondonRange();

   // Send daily assessment once at London close
   if(t.hour == LON_END_H && t.min == 0 && !g_assessment_sent && g_rh > 0) {
      SendDailyAssessment();
      g_assessment_sent = true;
   }

   switch(g_state) {
      case IDLE:
         // Transition to sweep-watching at London close if filters pass
         if(t.hour == LON_END_H && t.min == 0 && g_rh > 0 && CheckFilters()) {
            DrawNYBox();
            g_state = WAITING_SWEEP;
         }
         break;
      case WAITING_SWEEP:  OnWaitingSweep(t);  break;
      case WAITING_HUMAN:  OnWaitingHuman(t);  break;
      case MANAGING:       ManageTrades(t);    break;
   }
}

//======================================================================
// FILTER CHECKS
//======================================================================

bool CheckFilters() {
   double rng = PriceToPips(g_rh - g_rl);

   if(rng < MIN_RANGE) {
      LogSkip(StringFormat("range %.0fp < min %dp (choppy)", rng, MIN_RANGE));
      return false;
   }
   if(rng > MAX_RANGE) {
      LogSkip(StringFormat("range %.0fp > max %dp (news day)", rng, MAX_RANGE));
      return false;
   }

   double avg5 = CalcRegimeAvgM1();
   if(avg5 > REGIME_THRESHOLD) {
      LogSkip(StringFormat("regime 5d avg %.0fp > %dp", avg5, REGIME_THRESHOLD));
      return false;
   }

   g_direction = CalcTrend();
   if(g_direction == "FLAT") {
      LogSkip("trend FLAT — no clear direction");
      return false;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double peak = MathMax(eq, g_day_start_eq);
   if(peak > 0 && (peak - eq) / peak * 100 >= FTMO_MAX_DD) {
      LogSkip("FTMO max DD breached — trading halted");
      return false;
   }

   Print(StringFormat("✅ Filters PASS — Dir:%s Range:%.0fp Regime:%.0fp",
         g_direction, rng, avg5));
   return true;
}

//======================================================================
// STATE HANDLERS
//======================================================================

void OnWaitingSweep(MqlDateTime &t) {
   if(!IsNYActive(t)) {
      if(t.hour >= NY_CLOSE_H) { g_state = IDLE; }
      return;
   }

   // Use bar index 1 — the bar that just COMPLETED (index 0 is the brand-new
   // bar that only has its opening tick and no useful H/L/C yet).
   double hi = iHigh(_Symbol, PERIOD_M1, 1);
   double lo = iLow(_Symbol,  PERIOD_M1, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);

   // Detect liquidity sweeps (fake-break beyond range, close back inside)
   if(!g_bull_sweep && hi > g_rh && cl <= g_rh) {
      g_bull_sweep = true;
      g_sweep_bar  = g_bars_seen;
      DrawSweepMarker(false, iTime(_Symbol, PERIOD_M1, 1), g_rh);
      Print("BULL sweep (spike above range) at ", TimeToString(iTime(_Symbol, PERIOD_M1, 1)));
   }
   if(!g_bear_sweep && lo < g_rl && cl >= g_rl) {
      g_bear_sweep = true;
      g_sweep_bar  = g_bars_seen;
      DrawSweepMarker(true, iTime(_Symbol, PERIOD_M1, 1), g_rl);
      Print("BEAR sweep (spike below range) at ", TimeToString(iTime(_Symbol, PERIOD_M1, 1)));
   }

   bool can_buy  = g_bull_sweep && g_direction != "SELL";
   bool can_sell = g_bear_sweep && g_direction != "BUY";
   if((!can_buy && !can_sell) || g_bars_seen <= g_sweep_bar) return;

   // Count confirmation bars closing beyond range
   if(can_buy  && cl > g_rh) g_confirm_cnt++;
   else if(can_sell && cl < g_rl) g_confirm_cnt++;
   else g_confirm_cnt = 0;

   if(g_confirm_cnt >= CONFIRM_BARS) {
      string dir   = can_buy ? "BUY" : "SELL";
      // Match HTML engine: entry = bid + (spread+slip) for BUY, bid - (spread+slip) for SELL
      // Using BID as the reference (≈ bar close), same as HTML's  en = eb.c + adj
      // Do NOT use SYMBOL_ASK for BUY — ask already includes spread, would double-count it
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     + (SPREAD_PIPS + SLIP_PIPS) * (can_buy ? PipToPrice(1) : -PipToPrice(1));

      SendSetupAlert(price, dir);
      g_alert_bar = g_bars_seen;

      // In Strategy Tester there is no human to confirm — always auto-enter.
      // In live/demo mode, respect the SEMI_AUTO input.
      if(SEMI_AUTO && !MQLInfoInteger(MQL_TESTER)) {
         g_state = WAITING_HUMAN;
      } else {
         ExecuteEntry(price, dir);
         // g_state is set to MANAGING inside ExecuteEntry
      }
   }
}

//----------------------------------------------------------------------
void OnWaitingHuman(MqlDateTime &t) {
   // Timeout — setup expired
   if(CONFIRM_TIMEOUT > 0 && g_bars_seen > g_alert_bar + CONFIRM_TIMEOUT) {
      Notify("⏰ LRB SETUP EXPIRED — no human confirmation received");
      Print("Setup expired");
      g_state = IDLE;
      return;
   }
   if(t.hour >= NY_CLOSE_H) { g_state = IDLE; return; }

   // Detect if human manually opened positions (or EA opened them)
   if(HasOurPositions()) {
      ulong t1 = 0, t2 = 0;
      FindOurPositions(t1, t2);
      g_t1_ticket = t1;
      g_t2_ticket = t2;
      if(PositionSelectByTicket(t1))
         g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      g_t2_sl   = g_direction == "BUY"
                  ? g_entry - PipToPrice(SL_PIPS)
                  : g_entry + PipToPrice(SL_PIPS);
      g_cp1_hit  = false;
      g_t1_closed = false;
      g_cp3_hit  = false;
      DrawCPLines();
      g_state    = MANAGING;
      Print("Trade live — managing positions. Entry:", g_entry);
   }
}

//----------------------------------------------------------------------
void ManageTrades(MqlDateTime &t) {
   // All positions closed externally (SL hit by broker or user closed manually)
   if(!HasOurPositions()) {
      if(!g_t1_closed) {
         // T2 SL was hit (or both closed externally)
         string outcome = g_cp1_hit ? "BREAKEVEN STOP" : "STOP LOSS";
         double loss_p  = g_cp1_hit ? 0 : SL_PIPS;
         Notify(StringFormat("⛔ LRB %s HIT\n%s | Entry: %.1f | Loss: ~%.0fp",
                outcome, g_direction, g_entry, loss_p));
      }
      g_state = IDLE;
      return;
   }

   double cur      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // Use bar[1] H/L extremes for CP threshold checks — this mirrors how the
   // HTML backtester detects CP hits (bar.hi / bar.lo), catching intrabar moves.
   double bar1_hi  = iHigh(_Symbol, PERIOD_M1, 1);
   double bar1_lo  = iLow(_Symbol,  PERIOD_M1, 1);
   double pips     = (g_direction == "BUY"
                      ? bar1_hi - g_entry   // best intrabar price reached for BUY
                      : g_entry - bar1_lo)  // best intrabar price reached for SELL
                     / PipToPrice(1);

   // CP1 +40p — move both SLs to breakeven
   if(pips >= CP1_PIPS && !g_cp1_hit) {
      g_cp1_hit = true;
      g_t2_sl   = g_entry;
      MoveAllSL(g_entry);
      Notify(StringFormat(
         "✅ LRB CP1 +%dp — SL MOVED TO BREAKEVEN (%.1f)\n"
         "Direction: %s | Worst case from now: ZERO loss",
         CP1_PIPS, g_entry, g_direction));
   }

   // CP2 +80p — close T1, trail T2 SL to entry+40p
   if(pips >= CP2_PIPS && !g_t1_closed) {
      g_t1_closed = true;
      CloseT1();
      double new_sl = g_direction == "BUY"
                      ? g_entry + PipToPrice(CP1_PIPS)
                      : g_entry - PipToPrice(CP1_PIPS);
      g_t2_sl = new_sl;
      MoveT2SL(new_sl);
      Notify(StringFormat(
         "💰 LRB CP2 +%dp — T1 CLOSED at +%dp profit\n"
         "T2 SL trailed to entry+%dp (%.1f) | T2 still running",
         CP2_PIPS, CP2_PIPS, CP1_PIPS, new_sl));
   }

   // CP3 +120p — trail T2 SL to entry+80p
   if(pips >= CP3_PIPS && g_t1_closed && !g_cp3_hit) {
      g_cp3_hit = true;
      double new_sl = g_direction == "BUY"
                      ? g_entry + PipToPrice(CP2_PIPS)
                      : g_entry - PipToPrice(CP2_PIPS);
      if((g_direction == "BUY"  && new_sl > g_t2_sl) ||
         (g_direction == "SELL" && new_sl < g_t2_sl)) {
         g_t2_sl = new_sl;
         MoveT2SL(new_sl);
         Notify(StringFormat(
            "📈 LRB CP3 +%dp — T2 SL trailed to entry+%dp (%.1f)\n"
            "MINIMUM locked profit: +%dp on T2",
            CP3_PIPS, CP2_PIPS, new_sl, CP2_PIPS));
      }
   }

   // CP4 +250p — full target, close everything
   if(pips >= CP4_PIPS) {
      CloseAll();
      Notify(StringFormat(
         "🎯 LRB CP4 FULL TARGET! +%dp\n"
         "T1: +%dp | T2: +%dp | Avg result: +%.0fp\n"
         "%s trade complete.",
         CP4_PIPS, CP2_PIPS, CP4_PIPS, (CP2_PIPS + CP4_PIPS) / 2.0,
         g_direction));
      g_state = IDLE;
      return;
   }

   // Session force-exit at NY close — use current BID not the intrabar extreme
   if(t.hour >= NY_CLOSE_H) {
      double exit_pips = (g_direction == "BUY" ? cur - g_entry : g_entry - cur) / PipToPrice(1);
      string outcome   = exit_pips > 0.5 ? "WIN" : exit_pips < -0.5 ? "LOSS" : "BREAKEVEN";
      CloseAll();
      Notify(StringFormat(
         "⏰ LRB SESSION CLOSE — %s\n"
         "%s | Exit: %.0fp | %s",
         g_direction, TimeToString(TimeCurrent()), exit_pips, outcome));
      g_state = IDLE;
      return;
   }

   // FTMO daily guard
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_eq > 0 && (g_day_start_eq - eq) / g_day_start_eq * 100 >= FTMO_DAILY_GUARD) {
      CloseAll();
      Notify(StringFormat(
         "🚨 LRB FTMO DAILY GUARD TRIGGERED\n"
         "Day loss exceeded %.1f%% — all positions closed, trading paused today",
         FTMO_DAILY_GUARD));
      g_state = IDLE;
   }
}

//======================================================================
// FILTER CALCULATIONS (mirror Python engine exactly)
//======================================================================

// --- Regime Filter: 5-day rolling average London range (M1 bars, same as Python)
// Matches HTML: days.slice(di-5, di) — uses the 5 days BEFORE today, excludes today.
double CalcRegimeAvgM1() {
   double daily_ranges[];
   int    days_found  = 0;
   int    total_m1    = iBars(_Symbol, PERIOD_M1);
   string cur_day     = "";
   double day_hi      = 0, day_lo = DBL_MAX;
   bool   has_london  = false;

   // Exclude today so the average matches Python/HTML (prev 5 days only)
   MqlDateTime now_t; TimeToStruct(TimeCurrent(), now_t);
   string today_str = StringFormat("%04d.%02d.%02d", now_t.year, now_t.mon, now_t.day);

   for(int i = 0; i < total_m1 && days_found < REGIME_LOOKBACK; i++) {
      datetime bt = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime td; TimeToStruct(bt, td);
      if(td.day_of_week == 0 || td.day_of_week == 6) continue;

      string day_str = StringFormat("%04d.%02d.%02d", td.year, td.mon, td.day);
      if(day_str != cur_day) {
         // Save previous day — but never save today (matches HTML di-slice logic)
         if(cur_day != "" && has_london && cur_day != today_str) {
            ArrayResize(daily_ranges, days_found + 1);
            daily_ranges[days_found] = PriceToPips(day_hi - day_lo);
            days_found++;
         }
         cur_day    = day_str;
         day_hi     = 0; day_lo = DBL_MAX; has_london = false;
      }

      if(td.hour >= LON_START_H && td.hour < LON_END_H) {
         day_hi    = MathMax(day_hi, iHigh(_Symbol, PERIOD_M1, i));
         day_lo    = MathMin(day_lo, iLow(_Symbol,  PERIOD_M1, i));
         has_london = true;
      }
   }

   if(days_found < 2) return 0;
   double sum = 0;
   for(int i = 0; i < days_found; i++) sum += daily_ranges[i];
   return sum / days_found;
}

// --- Trend Filter: 20-day high/low position ratio (M1-derived daily closes, same as Python)
// Iterates bars newest→oldest. We capture the FIRST bar encountered per day (= that day's
// most-recent close), matching HTML dc = dayMap.get(d).slice(-1)[0].c
string CalcTrend() {
   double daily_closes[];
   int    days_found = 0;
   int    total_m1   = iBars(_Symbol, PERIOD_M1);
   string cur_day    = "";
   double day_newest_close = 0; // close of the most-recent bar seen for cur_day

   for(int i = 0; i < total_m1; i++) {
      datetime bt = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime td; TimeToStruct(bt, td);
      if(td.day_of_week == 0 || td.day_of_week == 6) continue;

      string day_str = StringFormat("%04d.%02d.%02d", td.year, td.mon, td.day);
      if(day_str != cur_day) {
         // Save the previously accumulated day — day_newest_close was set when we
         // FIRST encountered that day (= its most-recent bar since we go newest→oldest)
         if(cur_day != "" && day_newest_close > 0) {
            ArrayResize(daily_closes, days_found + 1);
            daily_closes[days_found] = day_newest_close;
            days_found++;
            if(days_found > TREND_LB + 2) break;
         }
         cur_day = day_str;
         day_newest_close = iClose(_Symbol, PERIOD_M1, i); // first encounter = newest bar
      }
      // Do NOT overwrite day_newest_close — we only want the first (newest) bar
   }

   if(days_found < TREND_MIN_CLOSES) return "FLAT";

   int end = MathMin(days_found, TREND_LB + 1);
   double hi = 0, lo = DBL_MAX;
   for(int i = 1; i < end; i++) {
      hi = MathMax(hi, daily_closes[i]);
      lo = MathMin(lo, daily_closes[i]);
   }

   double rng = hi - lo;
   if(rng < _Point) return "FLAT";

   double today = (daily_closes[0] > 0) ? daily_closes[0] : daily_closes[1];
   double pos   = MathMax(0.0, MathMin(1.0, (today - lo) / rng));

   if(pos > TREND_UP_POS) return "BUY";
   if(pos < TREND_DN_POS) return "SELL";
   return "FLAT";
}

//======================================================================
// CHART DRAWINGS
//======================================================================

// London range box — blue, updates live during London session
void DrawLondonBox() {
   if(g_rh == 0 || g_rl == 0) return;
   string name = "LRB_LON_" + g_day_tag;
   datetime t2  = iTime(_Symbol, PERIOD_M1, 0) + 60;

   if(ObjectFind(0, name) >= 0) {
      // Update existing box right edge and price levels as range expands
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name,  OBJPROP_PRICE, 0, g_rh);
      ObjectSetDouble(0, name,  OBJPROP_PRICE, 1, g_rl);
      // Update label position
      ObjectSetDouble(0, "LRB_LON_LBL_" + g_day_tag, OBJPROP_PRICE, 0, g_rh);
   } else {
      // Create new box
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_lon_start_dt, g_rh, t2, g_rl);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      LON_BOX_COLOR);
      ObjectSetInteger(0, name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);  // draws behind candles = visual transparency
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);

      string lbl = "LRB_LON_LBL_" + g_day_tag;
      ObjectCreate(0, lbl, OBJ_TEXT, 0, g_lon_start_dt, g_rh);
      ObjectSetString(0,  lbl, OBJPROP_TEXT,     "LONDON");
      ObjectSetInteger(0, lbl, OBJPROP_COLOR,    LON_BOX_COLOR);
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);
   }
   ChartRedraw();
}

// NY session box — orange, drawn once at London close
void DrawNYBox() {
   if(g_ny_start_dt == 0) return;
   string   name     = "LRB_NY_" + g_day_tag;
   datetime ny_end   = g_ny_start_dt + (NY_CLOSE_H - NY_OPEN_H) * 3600 + 3600;
   double   buf      = PipToPrice(60);

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, g_ny_start_dt, g_rh + buf, ny_end, g_rl - buf);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      NY_BOX_COLOR);
   ObjectSetInteger(0, name, OBJPROP_FILL,        true);
   ObjectSetInteger(0, name, OBJPROP_BACK,        true);  // draws behind candles = visual transparency
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);

   string lbl = "LRB_NY_LBL_" + g_day_tag;
   ObjectCreate(0, lbl, OBJ_TEXT, 0, g_ny_start_dt, g_rh + buf);
   ObjectSetString(0,  lbl, OBJPROP_TEXT,     "NY SESSION");
   ObjectSetInteger(0, lbl, OBJPROP_COLOR,    NY_BOX_COLOR);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);
   ChartRedraw();
}

// Yellow triangle marking where a sweep occurred
void DrawSweepMarker(bool is_bear, datetime t, double price) {
   string name = StringFormat("LRB_SWEEP_%s_%d", g_day_tag, (int)t);
   ENUM_OBJECT arrow = is_bear ? OBJ_ARROW_UP : OBJ_ARROW_DOWN;
   ObjectCreate(0, name, arrow, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clrYellow);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP,   is_bear ? "BEAR sweep (range low tagged)" : "BULL sweep (range high tagged)");
}

// Directional arrow at entry bar
void DrawEntryArrow(datetime t, double price, string dir) {
   if(!DRAW_ENTRY_ARROW) return;
   string       name  = "LRB_ENTRY_" + g_day_tag;
   ENUM_OBJECT  arrow = (dir == "BUY") ? OBJ_ARROW_BUY : OBJ_ARROW_SELL;
   color        col   = (dir == "BUY") ? clrLime : clrRed;
   ObjectCreate(0, name, arrow, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     col);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     3);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP,
      StringFormat("LRB ENTRY %s @ %.1f | SL: %dp | Target: +%dp", dir, price, SL_PIPS, CP4_PIPS));
   ChartRedraw();
}

// Dotted horizontal lines for each CP level + solid red SL
void DrawCPLines() {
   if(!DRAW_CP_LINES || g_entry == 0) return;

   int    cp_vals[] = { SL_PIPS,   CP1_PIPS,   CP2_PIPS,       CP3_PIPS,       CP4_PIPS };
   string cp_lbls[] = { "SL",      "CP1 BE",   "CP2 T1 Close", "CP3 Trail",    "CP4 Target" };
   color  cp_cols[] = { clrRed,    clrYellow,  clrLime,        clrAqua,        clrGold };
   ENUM_LINE_STYLE cp_styles[] = { STYLE_SOLID, STYLE_DOT, STYLE_DOT, STYLE_DOT, STYLE_DASH };
   bool   is_sl[]   = { true, false, false, false, false };

   for(int i = 0; i < 5; i++) {
      double sign = is_sl[i] ? -1.0 : 1.0;   // SL is below for BUY
      double lvl  = g_direction == "BUY"
                    ? g_entry + sign * PipToPrice(cp_vals[i])
                    : g_entry - sign * PipToPrice(cp_vals[i]);

      string name = StringFormat("LRB_CP%d_%s", i, g_day_tag);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, lvl);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      cp_cols[i]);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      cp_styles[i]);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      is_sl[i] ? 2 : 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0,  name, OBJPROP_TOOLTIP,
         StringFormat("%s %+dp (%.1f)", cp_lbls[i], is_sl[i] ? -cp_vals[i] : cp_vals[i], lvl));
   }
   ChartRedraw();
}

//======================================================================
// ALERT & NOTIFICATION HELPERS
//======================================================================

// Print + Alert popup + mobile push notification
void Notify(string msg) {
   Print(msg);
   Alert(msg);
   SendNotification(msg);  // requires MetaQuotes ID configured in MT5 terminal
}

void SendSetupAlert(double price, string dir) {
   double sl   = dir == "BUY" ? price - PipToPrice(SL_PIPS)  : price + PipToPrice(SL_PIPS);
   double tp   = dir == "BUY" ? price + PipToPrice(CP4_PIPS)  : price - PipToPrice(CP4_PIPS);
   double rng  = PriceToPips(g_rh - g_rl);
   double avg5 = CalcRegimeAvgM1();
   string confirm_msg = SEMI_AUTO
      ? StringFormat("Confirm entry within %d bar(s)", CONFIRM_TIMEOUT)
      : "AUTO-ENTERING now";

   string msg = StringFormat(
      "🔔 LRB V2 SETUP READY\n"
      "━━━━━━━━━━━━━━━━━━━━━━\n"
      "Direction : %s | Trend: %s\n"
      "Entry     : ~%.1f\n"
      "Stop Loss : %.1f  (-%dp)\n"
      "Target    : %.1f  (+%dp)  1:%.1fR\n"
      "London Range : %.0f–%.0f (%.0fp)\n"
      "Regime 5d avg: %.0fp\n"
      "Risk: %.1f%% per leg  (%.1f%% total)\n"
      "━━━━━━━━━━━━━━━━━━━━━━\n"
      "%s",
      dir, g_direction,
      price,
      sl, SL_PIPS,
      tp, CP4_PIPS, (double)CP4_PIPS / SL_PIPS,
      g_rl, g_rh, rng,
      avg5,
      RISK_PCT_LEG, RISK_PCT_LEG * 2.0,
      confirm_msg);

   Notify(msg);
   DrawEntryArrow(iTime(_Symbol, PERIOD_M1, 0), price, dir);
}

// Daily assessment at London close — TRADE or SKIP with reasons
void SendDailyAssessment() {
   double rng   = PriceToPips(g_rh - g_rl);
   double avg5  = CalcRegimeAvgM1();
   string trend = CalcTrend();

   bool range_ok  = (rng >= MIN_RANGE && rng <= MAX_RANGE);
   bool regime_ok = (avg5 <= REGIME_THRESHOLD || avg5 == 0);
   bool trend_ok  = (trend != "FLAT");
   bool all_ok    = range_ok && regime_ok && trend_ok;

   string msg;
   if(all_ok) {
      msg = StringFormat(
         "📊 LRB DAY ASSESSMENT — ✅ WATCH & TRADE\n"
         "━━━━━━━━━━━━━━━━━━━━━━\n"
         "Range  : %.0fp ✓  (min:%d – max:%d)\n"
         "Regime : %.0fp 5d avg ✓  (limit:%d)\n"
         "Trend  : %s ✓\n"
         "━━━━━━━━━━━━━━━━━━━━━━\n"
         "Watching for %s SETUP at NY open (14:45 UTC)",
         rng, MIN_RANGE, MAX_RANGE,
         avg5, REGIME_THRESHOLD,
         trend, trend);
   } else {
      string reasons = "";
      if(!range_ok)  reasons += StringFormat("  • Range %.0fp %s\n", rng,
                                   rng < MIN_RANGE ? "(too narrow — choppy)" : "(too wide — news day)");
      if(!regime_ok) reasons += StringFormat("  • Regime %.0fp > %dp (volatile week)\n", avg5, REGIME_THRESHOLD);
      if(!trend_ok)  reasons += "  • Trend FLAT — no directional bias\n";

      msg = StringFormat(
         "📊 LRB DAY ASSESSMENT — ⏭ SKIP TODAY\n"
         "━━━━━━━━━━━━━━━━━━━━━━\n"
         "Reasons:\n%s"
         "━━━━━━━━━━━━━━━━━━━━━━\n"
         "Next check: tomorrow 08:00 UTC",
         reasons);
   }
   Notify(msg);
}

void LogSkip(string reason) {
   Print("SKIP: ", reason);
}

//======================================================================
// TRADE EXECUTION
//======================================================================

void ExecuteEntry(double price, string dir) {
   double bal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_usd = bal * RISK_PCT_LEG / 100.0;

   // Robust lot calculation: risk_usd = lots * (SL_distance / tick_size) * tick_value
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double sl_dist   = PipToPrice(SL_PIPS);
   double lots      = 0.01;
   if(tick_val > 0 && tick_size > 0 && sl_dist > 0)
      lots = NormalizeDouble(risk_usd / ((sl_dist / tick_size) * tick_val), 2);
   lots = MathMax(lots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   lots = MathMin(lots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));

   double sl = dir == "BUY" ? price - sl_dist : price + sl_dist;

   bool ok1 = false, ok2 = false;
   if(dir == "BUY") {
      ok1 = trade.Buy(lots,  _Symbol, price, sl, 0, "LRB_T1");
      if(ok1) { g_t1_ticket = trade.ResultOrder(); g_entry = trade.ResultPrice(); }
      ok2 = trade.Buy(lots,  _Symbol, price, sl, 0, "LRB_T2");
      if(ok2) g_t2_ticket = trade.ResultOrder();
   } else {
      ok1 = trade.Sell(lots, _Symbol, price, sl, 0, "LRB_T1");
      if(ok1) { g_t1_ticket = trade.ResultOrder(); g_entry = trade.ResultPrice(); }
      ok2 = trade.Sell(lots, _Symbol, price, sl, 0, "LRB_T2");
      if(ok2) g_t2_ticket = trade.ResultOrder();
   }

   // Fallback: if fill price unavailable (e.g. order queued), use requested price
   if(g_entry == 0) g_entry = price;
   // g_t2_sl tracks checkpoint movement — base it on actual fill, not requested price
   g_t2_sl     = dir == "BUY" ? g_entry - sl_dist : g_entry + sl_dist;
   g_cp1_hit   = false;
   g_t1_closed = false;
   g_cp3_hit   = false;

   Print(StringFormat("Entered %s | lots=%.2f | entry=%.1f | SL=%.1f | T1=%I64u T2=%I64u",
         dir, lots, price, sl, g_t1_ticket, g_t2_ticket));
   DrawCPLines();
   g_state = MANAGING;
}

//======================================================================
// POSITION HELPERS
//======================================================================

bool HasOurPositions() {
   for(int i = 0; i < PositionsTotal(); i++) {
      PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) return true;
   }
   return false;
}

void FindOurPositions(ulong &t1, ulong &t2) {
   t1 = 0; t2 = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
      if(t1 == 0) t1 = ticket;
      else        t2 = ticket;
   }
}

void MoveAllSL(double sl) {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         trade.PositionModify(ticket, sl, 0);
   }
}

void MoveT2SL(double sl) {
   // Try stored ticket first, fall back to second EA position
   if(g_t2_ticket > 0 && PositionSelectByTicket(g_t2_ticket)) {
      trade.PositionModify(g_t2_ticket, sl, 0);
      return;
   }
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;
      if(++count == 2) { trade.PositionModify(ticket, sl, 0); break; }
   }
}

void CloseT1() {
   if(g_t1_ticket > 0 && PositionSelectByTicket(g_t1_ticket)) {
      trade.PositionClose(g_t1_ticket);
      return;
   }
   // Fallback: close first EA position
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         trade.PositionClose(ticket);
         break;
      }
   }
}

void CloseAll() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         trade.PositionClose(ticket);
   }
}

//======================================================================
// RANGE BUILDING
//======================================================================

// Called on each new bar during/just-after London session.
// Reads bar index 1 (the bar that just completed) for accurate H/L.
// Internally verifies the bar falls inside London hours — safe to call
// at the 14:00 bar-open to capture the final 13:59 London bar.
void UpdateLondonRange() {
   // Guard: only include bars whose time is inside the London session
   datetime prev_time = iTime(_Symbol, PERIOD_M1, 1);
   MqlDateTime prev_t;
   TimeToStruct(prev_time, prev_t);
   int prev_utc = ((prev_t.hour - BROKER_UTC_OFFSET) % 24 + 24) % 24;
   if(prev_utc < LON_START_H || prev_utc >= LON_END_H) return;

   double hi = iHigh(_Symbol, PERIOD_M1, 1);
   double lo = iLow(_Symbol,  PERIOD_M1, 1);

   if(g_rh == 0) { g_rh = hi; g_rl = lo; }
   else          { g_rh = MathMax(g_rh, hi); g_rl = MathMin(g_rl, lo); }

   DrawLondonBox();
}

// On EA attach: scan historical M1 bars to rebuild today's London range
void ScanTodayRange() {
   MqlDateTime now_t; TimeToStruct(TimeCurrent(), now_t);
   int utc_hour = ((now_t.hour - BROKER_UTC_OFFSET) % 24 + 24) % 24;

   // Only relevant if we're inside or past London session
   if(utc_hour < LON_START_H) return;

   int total = iBars(_Symbol, PERIOD_M1);
   for(int i = 0; i < total; i++) {
      datetime bt = iTime(_Symbol, PERIOD_M1, i);
      MqlDateTime tbar; TimeToStruct(bt, tbar);

      // Stop when we hit yesterday's bars
      if(tbar.year != now_t.year || tbar.mon != now_t.mon || tbar.day != now_t.day) break;

      // Only London session bars
      int bar_utc = ((tbar.hour - BROKER_UTC_OFFSET) % 24 + 24) % 24;
      if(bar_utc < LON_START_H || bar_utc >= LON_END_H) continue;

      g_rh = MathMax(g_rh, iHigh(_Symbol, PERIOD_M1, i));
      g_rl = MathMin(g_rl, iLow(_Symbol,  PERIOD_M1, i));
   }
   if(g_rh > 0) {
      DrawLondonBox();
      Print(StringFormat("Range restored from history: %.1f – %.1f (%.0fp)",
            g_rl, g_rh, PriceToPips(g_rh - g_rl)));
   }
}

//======================================================================
// UTILITY
//======================================================================

// 1 pip = PIP_FACTOR price units. Broker _Point is NOT used — the Python engine
// and HTML backtester define 1 pip = 1 price unit for US30 regardless of _Point.
double PipToPrice(double pips)   { return pips * PIP_FACTOR; }
double PriceToPips(double price) { return price / PIP_FACTOR; }

bool IsNYActive(MqlDateTime &t) {
   int min = t.hour * 60 + t.min;
   int ny_start = NY_OPEN_H * 60 + NY_OPEN_M + NY_DELAY_MIN;
   return (min >= ny_start && t.hour < NY_CLOSE_H
           && t.day_of_week > 0 && t.day_of_week < 6);
}

void ResetDay() {
   g_state           = IDLE;
   g_rh              = 0; g_rl = 0;
   g_direction       = "";
   g_sweep_bar       = -1; g_confirm_cnt = 0; g_alert_bar = -1;
   g_bull_sweep      = false; g_bear_sweep = false;
   g_cp1_hit         = false; g_t1_closed = false; g_cp3_hit = false;
   g_t1_ticket       = 0; g_t2_ticket = 0;
   g_bars_seen       = 0;
   g_assessment_sent = false;
   g_day_start_eq    = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   g_day_tag      = StringFormat("%04d%02d%02d", t.year, t.mon, t.day);
   g_lon_start_dt = StringToTime(StringFormat("%04d.%02d.%02d %02d:00",
                       t.year, t.mon, t.day, LON_START_H + BROKER_UTC_OFFSET));
   g_ny_start_dt  = StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
                       t.year, t.mon, t.day,
                       NY_OPEN_H + BROKER_UTC_OFFSET,
                       NY_OPEN_M + NY_DELAY_MIN));
}
