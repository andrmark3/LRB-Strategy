//+------------------------------------------------------------------+
//| LRB_V3_EA.mq5 — London Range Breakout V3 (Prop Firm Optimized) |
//| v3.02 — fix DST UTC offset not refreshed between winter/summer   |
//|                                                                  |
//| PROP FIRM BALANCE:                                              |
//|  - 1.0% risk per leg (2% total) — fast enough for 10% target   |
//|  - Tighter SL (75p) — smaller loss when wrong                  |
//|  - Faster BE (25p) — protect capital quickly                    |
//|  - Daily guard 3% — never blow a day                           |
//|  - Max DD guard 7% — stay under 10% prop firm limit            |
//|  - Skip Friday — quality over quantity                         |
//+------------------------------------------------------------------+
#property copyright "LRB Strategy V3"
#property version   "3.02"
#property strict

#include <Trade/Trade.mqh>

// Keep V3 self-contained so it compiles even if V2 include paths are missing.
#define EA_MAGIC 20301

//=== SESSION HOURS (UTC) ===
input group "=== SESSION HOURS (UTC) ==="
input int    LON_START_H      = 8;
input int    LON_END_H        = 14;
input int    NY_OPEN_H        = 14;
input int    NY_OPEN_M        = 30;
input int    NY_DELAY_MIN     = 15;
input int    NY_CLOSE_H       = 21;
input int    BROKER_UTC_OFFSET= 0;

//=== FILTERS ===
input group "=== FILTERS ==="
input int    MIN_RANGE        = 120;
input int    MAX_RANGE        = 350;
input int    REGIME_THRESHOLD = 300;
input int    REGIME_LOOKBACK  = 5;
input int    TREND_LB         = 20;
input int    TREND_MIN_CLOSES = 10;
input double TREND_UP_POS     = 0.65;
input double TREND_DN_POS     = 0.35;
input int    CONFIRM_BARS     = 1;
input bool   REQUIRE_SWEEP    = true;
input bool   SKIP_FRIDAY      = true;

//=== TRADE MANAGEMENT ===
input group "=== TRADE MANAGEMENT ==="
input int    SL_PIPS          = 75;
input int    CP1_PIPS         = 25;
input int    CP2_PIPS         = 75;
input int    CP3_PIPS         = 100;
input int    CP4_PIPS         = 250;
input int    SPREAD_PIPS      = 2;
input int    SLIP_PIPS        = 1;

//=== RISK MANAGEMENT ===
input group "=== RISK MANAGEMENT ==="
input double RISK_PCT_LEG     = 1.0;
input double FTMO_DAILY_GUARD = 3.0;
input double FTMO_MAX_DD      = 7.0;
input double PIP_FACTOR       = 1.0;
input int    MAX_TRADES_DAY   = 1;

//=== MODE ===
input group "=== MODE ==="
input bool   SEMI_AUTO        = true;
input int    CONFIRM_TIMEOUT  = 3;

//=== CHART VISUALS ===
input group "=== CHART VISUALS ==="
input color  LON_BOX_COLOR    = clrCornflowerBlue;
input color  NY_BOX_COLOR     = clrSandyBrown;
input bool   DRAW_CP_LINES    = true;
input bool   DRAW_ENTRY_ARROW = true;

//--- State Machine
enum EAState { IDLE, WAITING_SWEEP, WAITING_HUMAN, MANAGING };

//--- Global State
EAState  g_state           = IDLE;
double   g_rh              = 0,    g_rl = 0;
string   g_direction       = "";
int      g_sweep_bar       = -1;
int      g_bull_sweep_bar  = -1,   g_bear_sweep_bar = -1, g_alert_bar = -1;
int      g_bull_cnt        = 0,    g_bear_cnt = 0;
bool     g_bull_sweep      = false, g_bear_sweep = false;
bool     g_cp1_hit         = false, g_t1_closed = false, g_cp3_hit = false;
double   g_entry           = 0,    g_t2_sl = 0;
double   g_day_start_eq    = 0;
double   g_account_peak    = 0;
int      g_bars_seen       = 0;
int      g_trades_today    = 0;
ulong    g_t1_ticket       = 0,    g_t2_ticket = 0;
datetime g_lon_start_dt    = 0;
datetime g_ny_start_dt     = 0;
bool     g_assessment_sent = false;
string   g_day_tag         = "";
int      g_utc_offset      = 0;

CTrade trade;

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(30);

   int auto_offset = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
   g_utc_offset = (BROKER_UTC_OFFSET != 0) ? BROKER_UTC_OFFSET : auto_offset;

   Print("LRB V3 EA v3.02 loaded — PROP FIRM OPTIMIZED");
   Print(StringFormat("UTC offset:%d | SL:%dp CP1:%dp CP2:%dp CP4:%dp",
         g_utc_offset, SL_PIPS, CP1_PIPS, CP2_PIPS, CP4_PIPS));
   Print(StringFormat("Risk:%.1f%% per leg (%.1f%% total) | DailyGuard:%.1f%% MaxDD:%.1f%%",
         RISK_PCT_LEG, RISK_PCT_LEG*2, FTMO_DAILY_GUARD, FTMO_MAX_DD));

   ResetDay();
   ScanTodayRange();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void OnTick() {
   // Refresh UTC offset every tick — handles summer/winter DST (UTC+2 ↔ UTC+3).
   // OnInit fires once; without this, a Jan start locks in UTC+2 and all summer
   // months (Apr–Oct) use the wrong session times, breaking regime + ResetDay().
   if(BROKER_UTC_OFFSET == 0)
      g_utc_offset = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);

   datetime now = TimeCurrent();
   MqlDateTime t; TimeToStruct(now, t);
   int utc_hour = ((t.hour - g_utc_offset) % 24 + 24) % 24;
   t.hour = utc_hour;

   if(t.hour == LON_START_H && t.min == 0 && t.sec < 5
      && t.day_of_week > 0 && t.day_of_week < 6)
      ResetDay();

   int cur_bars = iBars(_Symbol, PERIOD_M1);
   if(cur_bars == g_bars_seen) return;
   g_bars_seen = cur_bars;

   if(t.hour >= LON_START_H && t.hour <= LON_END_H
      && t.day_of_week > 0 && t.day_of_week < 6)
      UpdateLondonRange();

   if(t.hour == LON_END_H && t.min == 0 && !g_assessment_sent && g_rh > 0) {
      SendDailyAssessment();
      g_assessment_sent = true;
   }

   switch(g_state) {
      case IDLE:
         if(t.hour == LON_END_H && t.min == 0 && g_rh > 0 && CheckFilters()) {
            if(SKIP_FRIDAY && t.day_of_week == 5) { Print("Skipping Friday"); break; }
            if(g_trades_today >= MAX_TRADES_DAY)  { Print("Max trades/day reached"); break; }
            DrawNYBox();
            g_state = WAITING_SWEEP;
         }
         break;
      case WAITING_SWEEP: OnWaitingSweep(t); break;
      case WAITING_HUMAN: OnWaitingHuman(t); break;
      case MANAGING:      ManageTrades(t);   break;
   }
}

//======================================================================
bool CheckFilters() {
   double rng = PriceToPips(g_rh - g_rl);
   if(rng < MIN_RANGE) { Print(StringFormat("SKIP Range %.0fp < %dp", rng, MIN_RANGE)); return false; }
   if(rng > MAX_RANGE) { Print(StringFormat("SKIP Range %.0fp > %dp", rng, MAX_RANGE)); return false; }

   double avg5 = CalcRegimeAvgM1();
   if(avg5 > REGIME_THRESHOLD) { Print(StringFormat("SKIP Regime %.0fp > %dp", avg5, REGIME_THRESHOLD)); return false; }

   g_direction = CalcTrend();
   if(g_direction == "FLAT") { Print("SKIP Trend FLAT"); return false; }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_account_peak > 0 && (g_account_peak - eq) / g_account_peak * 100.0 >= FTMO_MAX_DD) {
      Print(StringFormat("HALT MaxDD %.1f%% breached", (g_account_peak - eq) / g_account_peak * 100.0));
      return false;
   }

   Print(StringFormat("Filters PASS Dir:%s Range:%.0fp Regime:%.0fp", g_direction, rng, avg5));
   return true;
}

//======================================================================
void OnWaitingSweep(MqlDateTime &t) {
   if(!IsNYActive(t)) { if(t.hour >= NY_CLOSE_H) g_state = IDLE; return; }

   double hi = iHigh(_Symbol,  PERIOD_M1, 1);
   double lo = iLow(_Symbol,   PERIOD_M1, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);

   if(!g_bull_sweep && hi > g_rh && cl <= g_rh) {
      g_bull_sweep = true; g_bull_sweep_bar = g_bars_seen; g_sweep_bar = g_bars_seen;
      DrawSweepMarker(false, iTime(_Symbol, PERIOD_M1, 1), g_rh);
      Print("BULL sweep at ", TimeToString(iTime(_Symbol, PERIOD_M1, 1)));
   }
   if(!g_bear_sweep && lo < g_rl && cl >= g_rl) {
      g_bear_sweep = true; g_bear_sweep_bar = g_bars_seen; g_sweep_bar = g_bars_seen;
      DrawSweepMarker(true, iTime(_Symbol, PERIOD_M1, 1), g_rl);
      Print("BEAR sweep at ", TimeToString(iTime(_Symbol, PERIOD_M1, 1)));
   }

   bool can_buy  = g_bull_sweep && g_direction != "SELL";
   bool can_sell = g_bear_sweep && g_direction != "BUY";
   if(!can_buy && !can_sell) return;
   if(g_bars_seen <= g_sweep_bar) return;

   if(cl > g_rh)      { g_bull_cnt++; g_bear_cnt = 0; }
   else if(cl < g_rl) { g_bear_cnt++; g_bull_cnt = 0; }
   else               { g_bull_cnt = 0; g_bear_cnt = 0; }

   string dir = "";
   if(can_buy  && g_bull_cnt >= CONFIRM_BARS) dir = "BUY";
   if(dir == "" && can_sell && g_bear_cnt >= CONFIRM_BARS) dir = "SELL";
   if(dir == "") return;

   double price = iClose(_Symbol, PERIOD_M1, 1)
                  + (SPREAD_PIPS + SLIP_PIPS) * ((dir=="BUY") ? PipToPrice(1) : -PipToPrice(1));

   SendSetupAlert(price, dir);
   g_alert_bar = g_bars_seen;

   if(SEMI_AUTO && !MQLInfoInteger(MQL_TESTER)) g_state = WAITING_HUMAN;
   else ExecuteEntry(price, dir);
}

//----------------------------------------------------------------------
void OnWaitingHuman(MqlDateTime &t) {
   if(CONFIRM_TIMEOUT > 0 && g_bars_seen > g_alert_bar + CONFIRM_TIMEOUT) {
      Notify("LRB SETUP EXPIRED"); g_state = IDLE; return;
   }
   if(t.hour >= NY_CLOSE_H) { g_state = IDLE; return; }

   if(HasOurPositions()) {
      ulong t1 = 0, t2 = 0;
      FindOurPositions(t1, t2);
      g_t1_ticket = t1; g_t2_ticket = t2;
      if(PositionSelectByTicket(t1))
         g_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      g_t2_sl     = g_direction=="BUY" ? g_entry-PipToPrice(SL_PIPS) : g_entry+PipToPrice(SL_PIPS);
      g_cp1_hit   = false; g_t1_closed = false; g_cp3_hit = false;
      DrawCPLines();
      g_state = MANAGING;
   }
}

//----------------------------------------------------------------------
void ManageTrades(MqlDateTime &t) {
   if(!HasOurPositions()) { g_state = IDLE; return; }

   double _eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(_eq > g_account_peak) g_account_peak = _eq;

   double cl1 = iClose(_Symbol, PERIOD_M1, 1);
   double lo1 = iLow(_Symbol,   PERIOD_M1, 1);
   double hi1 = iHigh(_Symbol,  PERIOD_M1, 1);

   bool sl_hit = (g_direction=="BUY") ? lo1 <= g_t2_sl : hi1 >= g_t2_sl;
   if(sl_hit) {
      CloseAll();
      double raw = PriceToPips(g_direction=="BUY" ? g_t2_sl-g_entry : g_entry-g_t2_sl);
      Notify(StringFormat("%s | %s | ~%.0fp", g_cp1_hit?"BREAKEVEN STOP":"STOP LOSS", g_direction, raw));
      g_state = IDLE; return;
   }

   double pips = (g_direction=="BUY" ? cl1-g_entry : g_entry-cl1) / PipToPrice(1);

   if(pips >= CP1_PIPS && !g_cp1_hit) {
      g_cp1_hit = true; g_t2_sl = g_entry; MoveAllSL(g_entry);
      Notify(StringFormat("CP1 +%dp — SLs to BE (%.1f)", CP1_PIPS, g_entry));
   }

   if(pips >= CP2_PIPS && !g_t1_closed) {
      g_t1_closed = true; CloseT1();
      double nsl = g_direction=="BUY" ? g_entry+PipToPrice(CP1_PIPS) : g_entry-PipToPrice(CP1_PIPS);
      g_t2_sl = nsl; MoveT2SL(nsl);
      Notify(StringFormat("CP2 +%dp — T1 closed | T2 SL +%dp (%.1f)", CP2_PIPS, CP1_PIPS, nsl));
   }

   if(pips >= CP3_PIPS && g_t1_closed && !g_cp3_hit) {
      g_cp3_hit = true;
      double nsl = g_direction=="BUY" ? g_entry+PipToPrice(CP2_PIPS) : g_entry-PipToPrice(CP2_PIPS);
      if((g_direction=="BUY" && nsl>g_t2_sl) || (g_direction=="SELL" && nsl<g_t2_sl)) {
         g_t2_sl = nsl; MoveT2SL(nsl);
         Notify(StringFormat("CP3 +%dp — T2 SL +%dp (%.1f) | Min locked:+%dp",
                CP3_PIPS, CP2_PIPS, nsl, CP2_PIPS));
      }
   }

   if(pips >= CP4_PIPS) {
      CloseAll();
      Notify(StringFormat("FULL TARGET +%dp! T1:+%dp T2:+%dp | %s",
             CP4_PIPS, CP2_PIPS, CP4_PIPS, g_direction));
      g_state = IDLE; return;
   }

   if(t.hour >= NY_CLOSE_H) {
      double ep = (g_direction=="BUY" ? cl1-g_entry : g_entry-cl1) / PipToPrice(1);
      CloseAll();
      Notify(StringFormat("SESSION CLOSE %s | %.0fp | %s", g_direction, ep,
             ep>0?"WIN":ep<0?"LOSS":"BE"));
      g_state = IDLE; return;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_eq > 0 && (g_day_start_eq-eq)/g_day_start_eq*100.0 >= FTMO_DAILY_GUARD) {
      CloseAll();
      Notify(StringFormat("DAILY GUARD %.1f%% — paused today", FTMO_DAILY_GUARD));
      g_state = IDLE;
   }
}

//======================================================================
void ExecuteEntry(double price, string dir) {
   double bal      = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_usd = bal * RISK_PCT_LEG / 100.0;
   double sl_p     = PipToPrice(SL_PIPS);

   // Broker-safe lot sizing: risk_usd = lots * (SL_distance/tick_size) * tick_value
   double tick_val  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lots      = 0.01;
   if(tick_val > 0 && tick_size > 0 && sl_p > 0)
      lots = risk_usd / ((sl_p / tick_size) * tick_val);

   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vol_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(vol_step > 0) lots = MathFloor(lots / vol_step) * vol_step;
   lots = NormalizeDouble(lots, 2);
   lots = MathMax(lots, vol_min);
   lots = MathMin(lots, vol_max);

   double sl = dir=="BUY" ? price-sl_p : price+sl_p;

   bool ok1=false, ok2=false;
   if(dir=="BUY") {
      ok1 = trade.Buy(lots,  _Symbol, price, sl, 0, "LRB_T1");
      if(ok1){ g_t1_ticket=trade.ResultOrder(); g_entry=trade.ResultPrice(); }
      ok2 = trade.Buy(lots,  _Symbol, price, sl, 0, "LRB_T2");
      if(ok2) g_t2_ticket=trade.ResultOrder();
   } else {
      ok1 = trade.Sell(lots, _Symbol, price, sl, 0, "LRB_T1");
      if(ok1){ g_t1_ticket=trade.ResultOrder(); g_entry=trade.ResultPrice(); }
      ok2 = trade.Sell(lots, _Symbol, price, sl, 0, "LRB_T2");
      if(ok2) g_t2_ticket=trade.ResultOrder();
   }

   if(g_entry==0) g_entry=price;
   if(!ok1 && !ok2) {
      Print(StringFormat("Entry failed (%s). retcode=%d desc=%s lots=%.2f",
            dir, trade.ResultRetcode(), trade.ResultRetcodeDescription(), lots));
      g_state = IDLE;
      return;
   }

   g_t2_sl=dir=="BUY" ? g_entry-sl_p : g_entry+sl_p;
   g_cp1_hit=false; g_t1_closed=false; g_cp3_hit=false;
   g_trades_today++;
   Print(StringFormat("Entered %s lots=%.2f entry=%.1f SL=%.1f trades_today=%d",
         dir, lots, g_entry, sl, g_trades_today));
   DrawCPLines();
   g_state = MANAGING;
}

//======================================================================
bool HasOurPositions() {
   for(int i=0; i<PositionsTotal(); i++) {
      PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==EA_MAGIC) return true;
   }
   return false;
}

void FindOurPositions(ulong &t1, ulong &t2) {
   t1=0; t2=0;
   for(int i=0; i<PositionsTotal(); i++) {
      ulong tk=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=EA_MAGIC) continue;
      if(t1==0) t1=tk; else t2=tk;
   }
}

void MoveAllSL(double sl) {
   for(int i=0; i<PositionsTotal(); i++) {
      ulong tk=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==EA_MAGIC) trade.PositionModify(tk,sl,0);
   }
}

void MoveT2SL(double sl) {
   if(g_t2_ticket>0 && PositionSelectByTicket(g_t2_ticket)) { trade.PositionModify(g_t2_ticket,sl,0); return; }
   int cnt=0;
   for(int i=0; i<PositionsTotal(); i++) {
      ulong tk=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=EA_MAGIC) continue;
      if(++cnt==2){ trade.PositionModify(tk,sl,0); break; }
   }
}

void CloseT1() {
   if(g_t1_ticket>0 && PositionSelectByTicket(g_t1_ticket)) { trade.PositionClose(g_t1_ticket); return; }
   for(int i=0; i<PositionsTotal(); i++) {
      ulong tk=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==EA_MAGIC) { trade.PositionClose(tk); break; }
   }
}

void CloseAll() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong tk=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==EA_MAGIC) trade.PositionClose(tk);
   }
}

//======================================================================
void UpdateLondonRange() {
   datetime pt=iTime(_Symbol,PERIOD_M1,1);
   MqlDateTime pdt; TimeToStruct(pt,pdt);
   int pu=((pdt.hour-g_utc_offset)%24+24)%24;
   if(pu<LON_START_H || pu>=LON_END_H) return;
   double hi=iHigh(_Symbol,PERIOD_M1,1), lo=iLow(_Symbol,PERIOD_M1,1);
   if(g_rh==0){ g_rh=hi; g_rl=lo; } else { g_rh=MathMax(g_rh,hi); g_rl=MathMin(g_rl,lo); }
   DrawLondonBox();
}

void ScanTodayRange() {
   MqlDateTime nt; TimeToStruct(TimeCurrent(),nt);
   int uh=((nt.hour-g_utc_offset)%24+24)%24;
   if(uh<LON_START_H) return;
   int total=iBars(_Symbol,PERIOD_M1);
   for(int i=0; i<total; i++) {
      datetime bt=iTime(_Symbol,PERIOD_M1,i);
      MqlDateTime tb; TimeToStruct(bt,tb);
      if(tb.year!=nt.year||tb.mon!=nt.mon||tb.day!=nt.day) break;
      int bu=((tb.hour-g_utc_offset)%24+24)%24;
      if(bu<LON_START_H||bu>=LON_END_H) continue;
      g_rh=MathMax(g_rh,iHigh(_Symbol,PERIOD_M1,i));
      g_rl=MathMin(g_rl,iLow(_Symbol, PERIOD_M1,i));
   }
   if(g_rh>0) { DrawLondonBox(); Print(StringFormat("Range restored %.1f-%.1f (%.0fp)",g_rl,g_rh,PriceToPips(g_rh-g_rl))); }
}

//======================================================================
double CalcRegimeAvgM1() {
   double dr[]; int df=0, total=iBars(_Symbol,PERIOD_M1);
   string cd=""; double dh=0,dl=DBL_MAX; int lb=0;
   MqlDateTime nt; TimeToStruct(TimeCurrent(),nt);
   string ts=StringFormat("%04d.%02d.%02d",nt.year,nt.mon,nt.day);

   for(int i=0; i<total && df<REGIME_LOOKBACK; i++) {
      datetime bt=iTime(_Symbol,PERIOD_M1,i);
      MqlDateTime td; TimeToStruct(bt,td);
      if(td.day_of_week==0||td.day_of_week==6) continue;
      string ds=StringFormat("%04d.%02d.%02d",td.year,td.mon,td.day);
      if(ds!=cd) {
         if(cd!=""&&lb>=10&&cd!=ts) { ArrayResize(dr,df+1); dr[df]=PriceToPips(dh-dl); df++; }
         cd=ds; dh=0; dl=DBL_MAX; lb=0;
      }
      int bu=((td.hour-g_utc_offset)%24+24)%24;
      if(bu>=LON_START_H&&bu<LON_END_H) {
         double hi=iHigh(_Symbol,PERIOD_M1,i), lo=iLow(_Symbol,PERIOD_M1,i);
         if(dh==0){dh=hi;dl=lo;} else{dh=MathMax(dh,hi);dl=MathMin(dl,lo);}
         lb++;
      }
   }
   if(df==0) return 0;
   double s=0; for(int i=0;i<df;i++) s+=dr[i];
   return s/df;
}

string CalcTrend() {
   int total=iBars(_Symbol,PERIOD_D1), cls=0;
   double rhi=-DBL_MAX, rlo=DBL_MAX;
   for(int i=1; i<=TREND_LB&&i<total; i++) {
      double cl=iClose(_Symbol,PERIOD_D1,i);
      rhi=MathMax(rhi,cl); rlo=MathMin(rlo,cl); cls++;
   }
   if(cls<TREND_MIN_CLOSES||rhi<=rlo) return "FLAT";
   double pos=(iClose(_Symbol,PERIOD_D1,0)-rlo)/(rhi-rlo);
   if(pos>=TREND_UP_POS) return "BUY";
   if(pos<=TREND_DN_POS) return "SELL";
   return "FLAT";
}

//======================================================================
double PipToPrice(double p)  { return p*PIP_FACTOR; }
double PriceToPips(double p) { return p/PIP_FACTOR; }

bool IsNYActive(MqlDateTime &t) {
   int min=t.hour*60+t.min, ny=NY_OPEN_H*60+NY_OPEN_M+NY_DELAY_MIN;
   return (min>=ny && t.hour<NY_CLOSE_H && t.day_of_week>0 && t.day_of_week<6);
}

void ResetDay() {
   g_state=IDLE; g_rh=0; g_rl=0; g_direction="";
   g_sweep_bar=-1; g_bull_sweep_bar=-1; g_bear_sweep_bar=-1; g_alert_bar=-1;
   g_bull_cnt=0; g_bear_cnt=0;
   g_bull_sweep=false; g_bear_sweep=false;
   g_cp1_hit=false; g_t1_closed=false; g_cp3_hit=false;
   g_t1_ticket=0; g_t2_ticket=0;
   g_bars_seen=0; g_trades_today=0; g_assessment_sent=false;
   g_day_start_eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_eq>g_account_peak) g_account_peak=g_day_start_eq;
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   g_day_tag=StringFormat("%04d%02d%02d",t.year,t.mon,t.day);
   g_lon_start_dt=StringToTime(StringFormat("%04d.%02d.%02d %02d:00",
      t.year,t.mon,t.day,LON_START_H+g_utc_offset));
   g_ny_start_dt=StringToTime(StringFormat("%04d.%02d.%02d %02d:%02d",
      t.year,t.mon,t.day,NY_OPEN_H+g_utc_offset,NY_OPEN_M+NY_DELAY_MIN));
}

void Notify(string msg) {
   Print(msg);
   if(!MQLInfoInteger(MQL_TESTER)){ SendNotification(msg); Alert(msg); }
}

//======================================================================
void SendDailyAssessment() {
   double rng=PriceToPips(g_rh-g_rl), avg5=CalcRegimeAvgM1();
   string dir=CalcTrend();
   bool ok=(rng>=MIN_RANGE&&rng<=MAX_RANGE&&avg5<=REGIME_THRESHOLD&&dir!="FLAT");
   string msg=StringFormat(
      "LRB V3 DAY ASSESSMENT — %s\n"
      "Range  : %.0fp %s (min:%d max:%d)\n"
      "Regime : %.0fp 5d avg %s (limit:%d)\n"
      "Trend  : %s %s\n%s",
      ok?"WATCH & TRADE":"SKIP TODAY",
      rng,(rng>=MIN_RANGE&&rng<=MAX_RANGE)?"OK":"FAIL",MIN_RANGE,MAX_RANGE,
      avg5,avg5<=REGIME_THRESHOLD?"OK":"FAIL",REGIME_THRESHOLD,
      dir,dir!="FLAT"?"OK":"FLAT",
      ok?"Watching for "+dir+" SETUP at NY open (14:45 UTC)":"No trade today.");
   Print(msg);
   if(!MQLInfoInteger(MQL_TESTER)){ SendNotification(msg); Alert(msg); }
}

void SendSetupAlert(double price, string dir) {
   double rng=PriceToPips(g_rh-g_rl), avg5=CalcRegimeAvgM1();
   double sl=dir=="BUY"?price-PipToPrice(SL_PIPS):price+PipToPrice(SL_PIPS);
   double tp=dir=="BUY"?price+PipToPrice(CP4_PIPS):price-PipToPrice(CP4_PIPS);
   string msg=StringFormat(
      "LRB V3 SETUP READY\n"
      "Direction:%s Trend:%s\n"
      "Entry:~%.1f SL:%.1f (-%dp) TP:%.1f (+%dp) R:1:%.1f\n"
      "Range:%.1f-%.1f (%.0fp) Regime:%.0fp\n"
      "Risk:%.1f%% per leg (%.1f%% total)\n%s",
      dir,g_direction,price,sl,SL_PIPS,tp,CP4_PIPS,(double)CP4_PIPS/SL_PIPS,
      g_rl,g_rh,rng,avg5,RISK_PCT_LEG,RISK_PCT_LEG*2,
      (SEMI_AUTO&&!MQLInfoInteger(MQL_TESTER))?"Waiting confirmation...":"AUTO-ENTERING now");
   Print(msg);
   if(!MQLInfoInteger(MQL_TESTER)){ SendNotification(msg); Alert(msg); }
}

//======================================================================
// CHART DRAWING — using ObjectMove() instead of OBJPROP_PRICE1/2/TIME2
//======================================================================
void DrawLondonBox() {
   string name="LRB_LON_"+g_day_tag;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_RECTANGLE,0,g_lon_start_dt,g_rh,TimeCurrent(),g_rl);
   ObjectSetInteger(0,name,OBJPROP_COLOR,LON_BOX_COLOR);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   // Use ObjectMove to update anchor points — avoids OBJPROP_PRICE1/2/TIME2
   ObjectMove(0,name,0,g_lon_start_dt,g_rh);
   ObjectMove(0,name,1,TimeCurrent(),  g_rl);
}

void DrawNYBox() {
   string name="LRB_NY_"+g_day_tag;
   MqlDateTime nt; TimeToStruct(TimeCurrent(),nt);
   datetime end_dt=StringToTime(StringFormat("%04d.%02d.%02d %02d:00",
      nt.year,nt.mon,nt.day,NY_CLOSE_H+g_utc_offset));
   ObjectCreate(0,name,OBJ_RECTANGLE,0,
      g_ny_start_dt, g_rh+PipToPrice(10),
      end_dt,        g_rl-PipToPrice(10));
   ObjectSetInteger(0,name,OBJPROP_COLOR,NY_BOX_COLOR);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
}

void DrawSweepMarker(bool bear, datetime dt, double price) {
   string name=StringFormat("LRB_SW_%s_%s",bear?"BEAR":"BULL",g_day_tag);
   ObjectCreate(0,name,OBJ_ARROW,0,dt,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,bear?242:241);
   ObjectSetInteger(0,name,OBJPROP_COLOR,bear?clrRed:clrLime);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
}

void DrawCPLines() {
   if(!DRAW_CP_LINES||g_entry==0) return;
   bool ib=(g_direction=="BUY");
   string pfx="LRB_CP_"+g_day_tag;
   datetime t1=TimeCurrent(), t2=t1+3600*8;

   string sfx[5] ={"_SL","_CP1","_CP2","_CP3","_CP4"};
   int    pts[5] ={-SL_PIPS, CP1_PIPS, CP2_PIPS, CP3_PIPS, CP4_PIPS};
   color  clrs[5]={clrRed, clrYellow, clrLimeGreen, clrAqua, clrGold};

   for(int i=0; i<5; i++) {
      double pr=ib ? g_entry+PipToPrice(pts[i]) : g_entry-PipToPrice(pts[i]);
      string n=pfx+sfx[i];
      ObjectCreate(0,n,OBJ_TREND,0,t1,pr,t2,pr);
      ObjectSetInteger(0,n,OBJPROP_COLOR,    clrs[i]);
      ObjectSetInteger(0,n,OBJPROP_STYLE,    STYLE_DASH);
      ObjectSetInteger(0,n,OBJPROP_WIDTH,    1);
      ObjectSetInteger(0,n,OBJPROP_RAY_RIGHT,true);
   }
}