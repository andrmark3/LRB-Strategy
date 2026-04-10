//+------------------------------------------------------------------+
//| LRB_V2_Indicator.mq5 — London Range Breakout V2 Visual Overlay  |
//|                                                                  |
//| Draws on historical chart bars:                                  |
//|   • London session box  — BLUE  (08:00–14:00 UTC)               |
//|   • NY session box      — ORANGE (14:45–21:00 UTC)              |
//|   • Range high/low lines with pip label                          |
//|                                                                  |
//| Use alongside LRB_V2_EA.mq5 or standalone as a chart overlay.   |
//|                                                                  |
//| IMPORTANT: Set BROKER_UTC_OFFSET if your broker server time      |
//| is not UTC (e.g. UTC+3 broker → set 3).                         |
//+------------------------------------------------------------------+
#property copyright   "LRB Strategy"
#property version     "2.10"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

input group "=== SESSION HOURS (UTC) ==="
input int   LON_START_H       = 8;    // London start hour (UTC)
input int   LON_END_H         = 14;   // London end hour (UTC)
input int   NY_OPEN_H         = 14;   // NY open hour (UTC)
input int   NY_OPEN_M         = 30;   // NY open minute (UTC)
input int   NY_DELAY_MIN      = 15;   // Entry delay after NY open (KEY FIX)
input int   NY_CLOSE_H        = 21;   // NY close hour (UTC)
input int   BROKER_UTC_OFFSET = 0;    // Add this to convert UTC → broker time

input group "=== DISPLAY ==="
input int   LOOKBACK_DAYS     = 60;   // How many days of boxes to draw (history)
input bool  SHOW_LABELS       = true; // Show "LONDON" / "NY SESSION" text labels
input bool  SHOW_RANGE_PIPS   = true; // Show pip size label on London box
input bool  SHOW_HIGH_LOW     = true; // Draw range high/low dashed lines

input group "=== COLOURS ==="
input color LON_BOX_COLOR     = clrCornflowerBlue; // London box fill colour
input color NY_BOX_COLOR      = C'255,160,50';     // NY box fill colour  (orange)
input color LON_LINE_COLOR    = clrSteelBlue;      // London high/low line colour
input double PIP_FACTOR       = 1.0;               // 1.0 for US30 (_Point=1.0). Set 10.0 if _Point=0.1

//--- Object name prefix (all objects created by this indicator start with this)
#define OBJ_PREFIX "LRBI_"

//+------------------------------------------------------------------+
int OnInit() {
   IndicatorSetString(INDICATOR_SHORTNAME, "LRB London/NY Boxes");
   DrawAllBoxes();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[]) {
   // Full redraw when new bars arrive
   if(prev_calculated == 0 || rates_total != prev_calculated)
      DrawAllBoxes();
   return rates_total;
}

//======================================================================
// MAIN DRAWING LOGIC
//======================================================================

void DrawAllBoxes() {
   ObjectsDeleteAll(0, OBJ_PREFIX);

   // Get D1 bars to know which calendar dates to process
   datetime d1_times[];
   int d1_count = CopyTime(_Symbol, PERIOD_D1, 0, LOOKBACK_DAYS + 5, d1_times);
   if(d1_count <= 0) return;

   int boxes_drawn = 0;

   // Process each day from most recent backwards
   for(int d = d1_count - 1; d >= 0 && boxes_drawn < LOOKBACK_DAYS; d--) {
      MqlDateTime dt; TimeToStruct(d1_times[d], dt);

      // Skip weekends
      if(dt.day_of_week == 0 || dt.day_of_week == 6) continue;

      // Build UTC-adjusted session times for this calendar day
      // d1_times[d] is the broker open of that day — we reconstruct UTC-based sessions
      string date_str = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);

      // London session window in broker time
      datetime lon_start = StringToTime(date_str + " " +
                              PadTime(LON_START_H + BROKER_UTC_OFFSET, 0));
      datetime lon_end   = StringToTime(date_str + " " +
                              PadTime(LON_END_H   + BROKER_UTC_OFFSET, 0));

      // NY entry window (after delay) in broker time
      int ny_start_h     = NY_OPEN_H   + BROKER_UTC_OFFSET;
      int ny_start_m     = NY_OPEN_M   + NY_DELAY_MIN;
      if(ny_start_m >= 60) { ny_start_h++; ny_start_m -= 60; }
      datetime ny_start  = StringToTime(date_str + " " + PadTime(ny_start_h, ny_start_m));
      datetime ny_end    = StringToTime(date_str + " " +
                              PadTime(NY_CLOSE_H  + BROKER_UTC_OFFSET, 0));

      // Scan M1 bars for London session to get high/low
      MqlRates lon_bars[];
      int n = CopyRates(_Symbol, PERIOD_M1, lon_start, lon_end, lon_bars);
      if(n < 5) continue; // not enough London bars — skip day

      double rh = lon_bars[0].high, rl = lon_bars[0].low;
      for(int i = 1; i < n; i++) {
         rh = MathMax(rh, lon_bars[i].high);
         rl = MathMin(rl, lon_bars[i].low);
      }

      double rng_pips = (rh - rl) / (_Point * PIP_FACTOR);

      DrawDayBoxes(date_str, lon_start, lon_end, ny_start, ny_end, rh, rl, rng_pips);
      boxes_drawn++;
   }
   ChartRedraw();
}

//======================================================================
// DRAW ONE DAY
//======================================================================

void DrawDayBoxes(string tag,
                  datetime lon_t1, datetime lon_t2,
                  datetime ny_t1,  datetime ny_t2,
                  double rh, double rl, double rng_pips) {
   // --- London box ---
   string lon_name = OBJ_PREFIX + "LON_" + tag;
   if(ObjectCreate(0, lon_name, OBJ_RECTANGLE, 0, lon_t1, rh, lon_t2, rl)) {
      ObjectSetInteger(0, lon_name, OBJPROP_COLOR,      LON_BOX_COLOR);
      ObjectSetInteger(0, lon_name, OBJPROP_FILL,        true);
      ObjectSetInteger(0, lon_name, OBJPROP_BACK,        true);  // draws behind candles = visual transparency
      ObjectSetInteger(0, lon_name, OBJPROP_SELECTABLE,  false);
      ObjectSetString(0,  lon_name, OBJPROP_TOOLTIP,
         StringFormat("London Range: %.1f – %.1f  (%.0fp)", rl, rh, rng_pips));
   }

   // London label
   if(SHOW_LABELS) {
      string lbl = OBJ_PREFIX + "LON_LBL_" + tag;
      string txt  = SHOW_RANGE_PIPS
                    ? StringFormat("LDN  %.0fp", rng_pips)
                    : "LONDON";
      ObjectCreate(0, lbl, OBJ_TEXT, 0, lon_t1, rh);
      ObjectSetString(0,  lbl, OBJPROP_TEXT,      txt);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR,     LON_BOX_COLOR);
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE,  8);
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR,    ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE,false);
   }

   // Range high/low dashed lines extending through the NY session
   if(SHOW_HIGH_LOW) {
      // High line
      string hl_name = OBJ_PREFIX + "RH_" + tag;
      ObjectCreate(0, hl_name, OBJ_TREND, 0, lon_t1, rh, ny_t2, rh);
      ObjectSetInteger(0, hl_name, OBJPROP_COLOR,      LON_LINE_COLOR);
      ObjectSetInteger(0, hl_name, OBJPROP_STYLE,      STYLE_DASH);
      ObjectSetInteger(0, hl_name, OBJPROP_WIDTH,      1);
      ObjectSetInteger(0, hl_name, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, hl_name, OBJPROP_SELECTABLE, false);

      // Low line
      string ll_name = OBJ_PREFIX + "RL_" + tag;
      ObjectCreate(0, ll_name, OBJ_TREND, 0, lon_t1, rl, ny_t2, rl);
      ObjectSetInteger(0, ll_name, OBJPROP_COLOR,      LON_LINE_COLOR);
      ObjectSetInteger(0, ll_name, OBJPROP_STYLE,      STYLE_DASH);
      ObjectSetInteger(0, ll_name, OBJPROP_WIDTH,      1);
      ObjectSetInteger(0, ll_name, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, ll_name, OBJPROP_SELECTABLE, false);
   }

   // --- NY session box ---
   if(ny_t1 > 0 && ny_t2 > ny_t1) {
      // Scan actual M1 bars to get the real NY-session high/low
      double ny_high = rh, ny_low = rl; // fallback: London range bounds
      MqlRates ny_bars[];
      datetime scan_end = MathMin(ny_t2, TimeCurrent());
      if(scan_end > ny_t1) {
         int ny_n = CopyRates(_Symbol, PERIOD_M1, ny_t1, scan_end, ny_bars);
         if(ny_n > 0) {
            ny_high = ny_bars[0].high; ny_low = ny_bars[0].low;
            for(int i = 1; i < ny_n; i++) {
               ny_high = MathMax(ny_high, ny_bars[i].high);
               ny_low  = MathMin(ny_low,  ny_bars[i].low);
            }
         }
      }

      string ny_name = OBJ_PREFIX + "NY_" + tag;
      if(ObjectCreate(0, ny_name, OBJ_RECTANGLE, 0, ny_t1, ny_high, ny_t2, ny_low)) {
         ObjectSetInteger(0, ny_name, OBJPROP_COLOR,      NY_BOX_COLOR);
         ObjectSetInteger(0, ny_name, OBJPROP_FILL,        true);
         ObjectSetInteger(0, ny_name, OBJPROP_BACK,        true);  // draws behind candles = visual transparency
         ObjectSetInteger(0, ny_name, OBJPROP_SELECTABLE,  false);
         ObjectSetString(0,  ny_name, OBJPROP_TOOLTIP,     "NY Session — actual high/low");
      }

      if(SHOW_LABELS) {
         string ny_lbl = OBJ_PREFIX + "NY_LBL_" + tag;
         ObjectCreate(0, ny_lbl, OBJ_TEXT, 0, ny_t1, ny_high);
         ObjectSetString(0,  ny_lbl, OBJPROP_TEXT,      "NY");
         ObjectSetInteger(0, ny_lbl, OBJPROP_COLOR,     NY_BOX_COLOR);
         ObjectSetInteger(0, ny_lbl, OBJPROP_FONTSIZE,  8);
         ObjectSetInteger(0, ny_lbl, OBJPROP_ANCHOR,    ANCHOR_LEFT_LOWER);
         ObjectSetInteger(0, ny_lbl, OBJPROP_SELECTABLE,false);
      }
   }
}

//======================================================================
// UTILITY
//======================================================================

// Format hours/minutes as "HH:MM" with overflow handling (e.g. UTC+3 at 22:00 = "01:00")
string PadTime(int hour, int minute) {
   hour   = ((hour % 24) + 24) % 24;
   minute = ((minute % 60) + 60) % 60;
   return StringFormat("%02d:%02d", hour, minute);
}
