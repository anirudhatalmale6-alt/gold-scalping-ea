//+------------------------------------------------------------------+
//|                                              GoldScalpingEA.mq5  |
//|                                          Gold XAU/USD Scalping   |
//|                                     Trailing Pending Order Logic  |
//+------------------------------------------------------------------+
#property copyright "GoldScalpingEA"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Trade Settings ==="
input double   InpLotSize              = 0.01;    // Lot Size
input int      InpBuySellTrailingPt    = 100;     // Buy/Sell Trailing Point (pending order distance)
input int      InpStopLossTrailingPt   = 150;     // Stop Loss Trailing Point (after fill)
input int      InpSlippage             = 10;       // Slippage (points)

input group "=== Trade Mode ==="
input bool     InpSingleTradeMode     = true;     // Single Trade Mode (true=one trade, false=multiple)

input group "=== Session Filter ==="
input bool     InpTimeFilter          = true;     // Time Running (enable session filter)
input int      InpTimeStartHour       = 0;        // Time Start Running (hour, server time)
input int      InpTimeStartMinute     = 0;        // Time Start Running (minute)
input int      InpTimeEndHour         = 5;        // Time End Running (hour, server time)
input int      InpTimeEndMinute       = 0;        // Time End Running (minute)

input group "=== Market Activity Filter ==="
input int      InpATRPeriod           = 14;       // ATR Period
input double   InpATRThreshold        = 0.0;      // ATR Minimum Threshold (0=disabled)
input int      InpMaxSpread           = 20;       // Max Spread (points, 0=disabled)

input group "=== Display ==="
input bool     InpDisplayText         = true;     // Display Text on Chart

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
int            g_atrHandle;
double         g_atrValue;
double         g_dailyLots;
double         g_dailyPnL;
int            g_lastDay;
ulong          g_pendingTicket;
string         g_eaName = "GoldScalpingEA";
int            g_magicNumber = 123456;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create ATR indicator handle
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle");
      return(INIT_FAILED);
   }

   // Initialize daily tracking
   MqlDateTime dt;
   TimeCurrent(dt);
   g_lastDay = dt.day;
   g_dailyLots = 0.0;
   g_dailyPnL = 0.0;

   // Calculate existing daily stats from history
   CalcDailyStats();

   Print(g_eaName, " initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release ATR handle
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

   // Remove chart objects
   ObjectsDeleteAll(0, "GSE_");

   Print(g_eaName, " deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- Daily reset check ---
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != g_lastDay)
   {
      g_lastDay = dt.day;
      g_dailyLots = 0.0;
      g_dailyPnL = 0.0;
      CalcDailyStats();
   }

   // --- Update ATR ---
   double atrBuf[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuf) > 0)
      g_atrValue = atrBuf[0];

   // --- Calculate daily P&L (include open positions) ---
   CalcDailyStats();

   // --- Update chart display ---
   if(InpDisplayText)
      UpdateDisplay();

   // --- Check filters ---
   bool filtersPass = CheckFilters();

   // --- Count open positions and pending orders ---
   int openPositions = CountPositions();
   int pendingOrders = CountPendingOrders();

   // --- Manage open positions (trailing SL) ---
   if(openPositions > 0)
      ManageTrailingStopLoss();

   // --- Manage pending orders (trail them) ---
   if(pendingOrders > 0)
      TrailPendingOrders();

   // --- Place new pending orders if filters pass ---
   if(filtersPass)
   {
      if(InpSingleTradeMode)
      {
         // Single trade mode: only one pending + one position at a time
         if(openPositions == 0 && pendingOrders == 0)
            PlacePendingOrder();
      }
      else
      {
         // Multiple trade mode: allow new orders if no pending exists
         if(pendingOrders == 0)
            PlacePendingOrder();
      }
   }
}

//+------------------------------------------------------------------+
//| Check all filters                                                 |
//+------------------------------------------------------------------+
bool CheckFilters()
{
   // Session time filter
   if(InpTimeFilter)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      int currentMinutes = dt.hour * 60 + dt.min;
      int startMinutes   = InpTimeStartHour * 60 + InpTimeStartMinute;
      int endMinutes     = InpTimeEndHour * 60 + InpTimeEndMinute;

      if(startMinutes < endMinutes)
      {
         // Normal range (e.g., 08:00 to 17:00)
         if(currentMinutes < startMinutes || currentMinutes >= endMinutes)
            return false;
      }
      else
      {
         // Overnight range (e.g., 22:00 to 05:00)
         if(currentMinutes < startMinutes && currentMinutes >= endMinutes)
            return false;
      }
   }

   // ATR filter
   if(InpATRThreshold > 0.0 && g_atrValue < InpATRThreshold)
      return false;

   // Spread filter
   if(InpMaxSpread > 0)
   {
      double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Determine trend direction based on recent price action            |
//| Returns: +1 = uptrend (rising), -1 = downtrend (falling), 0=none |
//+------------------------------------------------------------------+
int DetectTrend()
{
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   double close3 = iClose(_Symbol, PERIOD_CURRENT, 3);

   // Rising: last 3 closes making higher values
   if(close1 > close2 && close2 > close3)
      return 1;  // Uptrend

   // Falling: last 3 closes making lower values
   if(close1 < close2 && close2 < close3)
      return -1; // Downtrend

   return 0; // No clear trend
}

//+------------------------------------------------------------------+
//| Place pending order based on trend                                |
//+------------------------------------------------------------------+
void PlacePendingOrder()
{
   int trend = DetectTrend();
   if(trend == 0)
      return; // No clear trend, skip

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailDistance = InpBuySellTrailingPt * point;

   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};

   request.action     = TRADE_ACTION_PENDING;
   request.symbol     = _Symbol;
   request.volume     = InpLotSize;
   request.deviation  = InpSlippage;
   request.magic      = g_magicNumber;
   request.type_filling = ORDER_FILLING_IOC;

   if(trend == 1)
   {
      // Price rising -> place SELL STOP below current price
      double sellStopPrice = NormalizeDouble(bid - trailDistance, digits);

      // Validate minimum distance
      double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(bid - sellStopPrice < minDist)
         sellStopPrice = NormalizeDouble(bid - minDist - point, digits);

      request.type  = ORDER_TYPE_SELL_STOP;
      request.price = sellStopPrice;
      request.comment = g_eaName + "_SellStop";
   }
   else if(trend == -1)
   {
      // Price falling -> place BUY STOP above current price
      double buyStopPrice = NormalizeDouble(ask + trailDistance, digits);

      // Validate minimum distance
      double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(buyStopPrice - ask < minDist)
         buyStopPrice = NormalizeDouble(ask + minDist + point, digits);

      request.type  = ORDER_TYPE_BUY_STOP;
      request.price = buyStopPrice;
      request.comment = g_eaName + "_BuyStop";
   }

   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         g_pendingTicket = result.order;
         Print("Pending order placed: ticket=", g_pendingTicket,
               " type=", (trend == 1 ? "SELL_STOP" : "BUY_STOP"),
               " price=", request.price);
      }
      else
      {
         Print("Order send failed: retcode=", result.retcode, " comment=", result.comment);
      }
   }
   else
   {
      Print("OrderSend error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Trail pending orders to maintain distance from price              |
//+------------------------------------------------------------------+
void TrailPendingOrders()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailDistance = InpBuySellTrailingPt * point;
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      if(orderType == ORDER_TYPE_SELL_STOP)
      {
         // Trail sell-stop upward as price rises
         double newPrice = NormalizeDouble(bid - trailDistance, digits);

         // Ensure minimum distance
         if(bid - newPrice < minDist)
            newPrice = NormalizeDouble(bid - minDist - point, digits);

         // Only move up, never down
         if(newPrice > currentPrice)
         {
            MqlTradeRequest request = {};
            MqlTradeResult  result  = {};

            request.action = TRADE_ACTION_MODIFY;
            request.order  = ticket;
            request.price  = newPrice;
            request.type_time = ORDER_TIME_GTC;

            if(OrderSend(request, result))
            {
               if(result.retcode == TRADE_RETCODE_DONE)
                  Print("Sell-stop trailed up to ", newPrice);
            }
         }
      }
      else if(orderType == ORDER_TYPE_BUY_STOP)
      {
         // Trail buy-stop downward as price falls
         double newPrice = NormalizeDouble(ask + trailDistance, digits);

         // Ensure minimum distance
         if(newPrice - ask < minDist)
            newPrice = NormalizeDouble(ask + minDist + point, digits);

         // Only move down, never up
         if(newPrice < currentPrice)
         {
            MqlTradeRequest request = {};
            MqlTradeResult  result  = {};

            request.action = TRADE_ACTION_MODIFY;
            request.order  = ticket;
            request.price  = newPrice;
            request.type_time = ORDER_TIME_GTC;

            if(OrderSend(request, result))
            {
               if(result.retcode == TRADE_RETCODE_DONE)
                  Print("Buy-stop trailed down to ", newPrice);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage trailing stop-loss for open positions                      |
//+------------------------------------------------------------------+
void ManageTrailingStopLoss()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slDistance = InpStopLossTrailingPt * point;
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      if(posType == POSITION_TYPE_SELL)
      {
         // For SELL: trail SL downward as price drops
         // SL is above the price
         double newSL = NormalizeDouble(ask + slDistance, digits);

         // Ensure minimum distance
         if(newSL - ask < minDist)
            newSL = NormalizeDouble(ask + minDist + point, digits);

         // Set initial SL or move it down (never up for sell)
         if(currentSL == 0.0 || newSL < currentSL)
         {
            MqlTradeRequest request = {};
            MqlTradeResult  result  = {};

            request.action   = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol   = _Symbol;
            request.sl       = newSL;
            request.tp       = 0;

            if(OrderSend(request, result))
            {
               if(result.retcode == TRADE_RETCODE_DONE)
                  Print("Sell trailing SL moved to ", newSL);
            }
         }
      }
      else if(posType == POSITION_TYPE_BUY)
      {
         // For BUY: trail SL upward as price rises
         // SL is below the price
         double newSL = NormalizeDouble(bid - slDistance, digits);

         // Ensure minimum distance
         if(bid - newSL < minDist)
            newSL = NormalizeDouble(bid - minDist - point, digits);

         // Set initial SL or move it up (never down for buy)
         if(currentSL == 0.0 || newSL > currentSL)
         {
            MqlTradeRequest request = {};
            MqlTradeResult  result  = {};

            request.action   = TRADE_ACTION_SLTP;
            request.position = ticket;
            request.symbol   = _Symbol;
            request.sl       = newSL;
            request.tp       = 0;

            if(OrderSend(request, result))
            {
               if(result.retcode == TRADE_RETCODE_DONE)
                  Print("Buy trailing SL moved to ", newSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                  |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == g_magicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count pending orders for this EA                                  |
//+------------------------------------------------------------------+
int CountPendingOrders()
{
   int count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == g_magicNumber &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Calculate daily stats (lots traded + P&L)                         |
//+------------------------------------------------------------------+
void CalcDailyStats()
{
   g_dailyLots = 0.0;
   g_dailyPnL  = 0.0;

   // Get today's start time
   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);

   // Check closed deals today
   if(HistorySelect(dayStart, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;

         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == g_magicNumber &&
            HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_OUT)
            {
               g_dailyLots += HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
               g_dailyPnL  += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                            + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                            + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            }
         }
      }
   }

   // Add unrealized P&L from open positions
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == g_magicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         g_dailyPnL += PositionGetDouble(POSITION_PROFIT)
                     + PositionGetDouble(POSITION_SWAP);
      }
   }
}

//+------------------------------------------------------------------+
//| Update on-chart display                                           |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double slippage = InpSlippage;

   int yPos = 30;
   int yStep = 20;
   color textColor = clrWhite;
   color labelColor = clrGold;
   int fontSize = 10;
   string fontName = "Consolas";

   // Header
   CreateLabel("GSE_Header", g_eaName, 15, yPos, clrGold, 12, fontName);
   yPos += yStep + 5;

   // Separator
   CreateLabel("GSE_Sep1", "----------------------------", 15, yPos, clrGray, fontSize, fontName);
   yPos += yStep;

   // Equity
   CreateLabel("GSE_Equity", "Equity:              " + DoubleToString(equity, 2), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Total lots traded today
   CreateLabel("GSE_Lots", "Lots Today:          " + DoubleToString(g_dailyLots, 2), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Daily P&L
   color pnlColor = (g_dailyPnL >= 0) ? clrLime : clrRed;
   CreateLabel("GSE_PnL", "P/L Today:           " + DoubleToString(g_dailyPnL, 2), 15, yPos, pnlColor, fontSize, fontName);
   yPos += yStep;

   // ATR
   CreateLabel("GSE_ATR", "ATR(" + IntegerToString(InpATRPeriod) + "):            " + DoubleToString(g_atrValue, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Slippage
   CreateLabel("GSE_Slip", "Slippage:            " + IntegerToString(InpSlippage), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Spread
   color spreadColor = (InpMaxSpread > 0 && spread > InpMaxSpread) ? clrRed : textColor;
   CreateLabel("GSE_Spread", "Spread:              " + DoubleToString(spread, 0), 15, yPos, spreadColor, fontSize, fontName);
   yPos += yStep;

   // Separator
   CreateLabel("GSE_Sep2", "----------------------------", 15, yPos, clrGray, fontSize, fontName);
   yPos += yStep;

   // EA Status
   string status = CheckFilters() ? "ACTIVE" : "PAUSED";
   color statusColor = CheckFilters() ? clrLime : clrOrangeRed;
   CreateLabel("GSE_Status", "Status:              " + status, 15, yPos, statusColor, fontSize, fontName);
   yPos += yStep;

   // Positions / Orders
   CreateLabel("GSE_Pos", "Positions:           " + IntegerToString(CountPositions()), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   CreateLabel("GSE_Ord", "Pending Orders:      " + IntegerToString(CountPendingOrders()), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Trade Mode
   string mode = InpSingleTradeMode ? "Single" : "Multiple";
   CreateLabel("GSE_Mode", "Trade Mode:          " + mode, 15, yPos, labelColor, fontSize, fontName);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create or update a text label on chart                            |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, string font)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| Trade event handler - detect when positions close                 |
//+------------------------------------------------------------------+
void OnTrade()
{
   // Recalculate daily stats when trade events occur
   CalcDailyStats();
}
//+------------------------------------------------------------------+
