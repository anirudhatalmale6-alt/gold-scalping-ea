//+------------------------------------------------------------------+
//|                                              GoldScalpingEA.mq5  |
//|                                          Gold XAU/USD Scalping   |
//|                                     Trailing Pending Order Logic  |
//+------------------------------------------------------------------+
#property copyright "GoldScalpingEA"
#property version   "1.02"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Trade Mode Enum                                                   |
//+------------------------------------------------------------------+
enum ENUM_TRADE_MODE
{
   TRADE_MODE_SINGLE   = 0,  // Single Trade
   TRADE_MODE_MULTIPLE = 1   // Multiple Trade
};

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
// Trade Settings
input double          InpLotSize           = 0.01;              // Lot Size
input int             InpBuySellTrailingPt = 100;               // Buy/Sell Trailing Point
input int             InpStopLossTrailingPt= 150;               // Stop Loss Trailing Point
input int             InpSlippage          = 10;                // Slippage (points)

// Trade Mode
input ENUM_TRADE_MODE InpTradeMode         = TRADE_MODE_SINGLE; // Trade Mode

// Session Filter
input bool            InpTimeFilter        = true;              // Time Running
input int             InpTimeStartHour     = 0;                 // Time Start Hour
input int             InpTimeStartMinute   = 0;                 // Time Start Minute
input int             InpTimeEndHour       = 5;                 // Time End Hour
input int             InpTimeEndMinute     = 0;                 // Time End Minute

// Market Activity Filter
input int             InpATRPeriod         = 14;                // ATR Period
input double          InpATRThreshold      = 0.0;               // ATR Min Threshold (0=off)
input int             InpMaxSpread         = 20;                // Max Spread (0=off)

// Display
input bool            InpDisplayText       = true;              // Display Text on Chart

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
CTrade         g_trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup trade object
   g_trade.SetExpertMagicNumber(g_magicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

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

   CalcDailyStats();

   Print(g_eaName, " initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);

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
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atrBuf) > 0)
      g_atrValue = atrBuf[0];

   // --- Calculate daily P&L ---
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
      if(InpTradeMode == TRADE_MODE_SINGLE)
      {
         if(openPositions == 0 && pendingOrders == 0)
            PlacePendingOrder();
      }
      else
      {
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
         if(currentMinutes < startMinutes || currentMinutes >= endMinutes)
            return false;
      }
      else
      {
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
      long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(currentSpread > InpMaxSpread)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Determine trend direction based on recent price action            |
//+------------------------------------------------------------------+
int DetectTrend()
{
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   double close3 = iClose(_Symbol, PERIOD_CURRENT, 3);

   if(close1 > close2 && close2 > close3)
      return 1;   // Uptrend

   if(close1 < close2 && close2 < close3)
      return -1;  // Downtrend

   return 0;
}

//+------------------------------------------------------------------+
//| Place pending order based on trend                                |
//+------------------------------------------------------------------+
void PlacePendingOrder()
{
   int trend = DetectTrend();
   if(trend == 0)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailDistance = InpBuySellTrailingPt * point;
   long   stopsLevel   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist      = stopsLevel * point;

   if(trend == 1)
   {
      // Price rising -> place SELL STOP below current price
      double sellStopPrice = NormalizeDouble(bid - trailDistance, digits);

      if(bid - sellStopPrice < minDist)
         sellStopPrice = NormalizeDouble(bid - minDist - point, digits);

      if(!g_trade.SellStop(InpLotSize, sellStopPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, g_eaName + "_SellStop"))
         Print("SellStop failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      else
         Print("Sell-stop placed at ", sellStopPrice);
   }
   else if(trend == -1)
   {
      // Price falling -> place BUY STOP above current price
      double buyStopPrice = NormalizeDouble(ask + trailDistance, digits);

      if(buyStopPrice - ask < minDist)
         buyStopPrice = NormalizeDouble(ask + minDist + point, digits);

      if(!g_trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, g_eaName + "_BuyStop"))
         Print("BuyStop failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      else
         Print("Buy-stop placed at ", buyStopPrice);
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
   long   stopsLevel   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist      = stopsLevel * point;

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
         double newPrice = NormalizeDouble(bid - trailDistance, digits);

         if(bid - newPrice < minDist)
            newPrice = NormalizeDouble(bid - minDist - point, digits);

         // Only move up, never down
         if(newPrice > currentPrice)
         {
            if(g_trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
               Print("Sell-stop trailed up to ", newPrice);
         }
      }
      else if(orderType == ORDER_TYPE_BUY_STOP)
      {
         double newPrice = NormalizeDouble(ask + trailDistance, digits);

         if(newPrice - ask < minDist)
            newPrice = NormalizeDouble(ask + minDist + point, digits);

         // Only move down, never up
         if(newPrice < currentPrice)
         {
            if(g_trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
               Print("Buy-stop trailed down to ", newPrice);
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
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = stopsLevel * point;

   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_SELL)
      {
         // SL is above the ask price for sell
         double newSL = NormalizeDouble(ask + slDistance, digits);

         if(newSL - ask < minDist)
            newSL = NormalizeDouble(ask + minDist + point, digits);

         // Set initial SL or move it down (never up for sell)
         if(currentSL == 0.0 || newSL < currentSL)
         {
            if(g_trade.PositionModify(ticket, newSL, currentTP))
               Print("Sell trailing SL moved to ", newSL);
         }
      }
      else if(posType == POSITION_TYPE_BUY)
      {
         // SL is below the bid price for buy
         double newSL = NormalizeDouble(bid - slDistance, digits);

         if(bid - newSL < minDist)
            newSL = NormalizeDouble(bid - minDist - point, digits);

         // Set initial SL or move it up (never down for buy)
         if(currentSL == 0.0 || newSL > currentSL)
         {
            if(g_trade.PositionModify(ticket, newSL, currentTP))
               Print("Buy trailing SL moved to ", newSL);
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

   MqlDateTime dt;
   TimeCurrent(dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);

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
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   int yPos = 30;
   int yStep = 20;
   color textColor = clrWhite;
   color labelColor = clrGold;
   int fontSize = 10;
   string fontName = "Consolas";

   // Header
   CreateLabel("GSE_Header", g_eaName, 15, yPos, clrGold, 12, fontName);
   yPos += yStep + 5;

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
   int atrDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   CreateLabel("GSE_ATR", "ATR(" + IntegerToString(InpATRPeriod) + "):            " + DoubleToString(g_atrValue, atrDigits), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Slippage
   CreateLabel("GSE_Slip", "Slippage:            " + IntegerToString(InpSlippage), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Spread
   color spreadColor = (InpMaxSpread > 0 && spread > InpMaxSpread) ? clrRed : textColor;
   CreateLabel("GSE_Spread", "Spread:              " + IntegerToString(spread), 15, yPos, spreadColor, fontSize, fontName);
   yPos += yStep;

   CreateLabel("GSE_Sep2", "----------------------------", 15, yPos, clrGray, fontSize, fontName);
   yPos += yStep;

   // EA Status
   bool active = CheckFilters();
   string status = active ? "ACTIVE" : "PAUSED";
   color statusColor = active ? clrLime : clrOrangeRed;
   CreateLabel("GSE_Status", "Status:              " + status, 15, yPos, statusColor, fontSize, fontName);
   yPos += yStep;

   // Positions / Orders
   CreateLabel("GSE_Pos", "Positions:           " + IntegerToString(CountPositions()), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   CreateLabel("GSE_Ord", "Pending Orders:      " + IntegerToString(CountPendingOrders()), 15, yPos, textColor, fontSize, fontName);
   yPos += yStep;

   // Trade Mode
   string mode = (InpTradeMode == TRADE_MODE_SINGLE) ? "Single" : "Multiple";
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
//| Trade event handler                                               |
//+------------------------------------------------------------------+
void OnTrade()
{
   CalcDailyStats();
}
//+------------------------------------------------------------------+
