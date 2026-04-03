//+------------------------------------------------------------------+
//|                                              GoldScalpingEA.mq5  |
//|                                          Gold XAU/USD Scalping   |
//|                                     Trailing Pending Order Logic  |
//+------------------------------------------------------------------+
#property copyright "GoldScalpingEA"
#property version   "1.09"

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
input int             InpMagicNumber       = 123456;            // Magic Number

// Trade Mode
input ENUM_TRADE_MODE InpTradeMode         = TRADE_MODE_SINGLE; // Trade Mode

// Session Filter
input bool            InpTimeFilter        = false;             // Time Running
input int             InpTimeStartHour     = 0;                 // Time Start Hour
input int             InpTimeStartMinute   = 0;                 // Time Start Minute
input int             InpTimeEndHour       = 23;                // Time End Hour
input int             InpTimeEndMinute     = 59;                // Time End Minute

// Market Activity Filter
input int             InpATRPeriod         = 14;                // ATR Period
input double          InpATRThreshold      = 0.0;               // ATR Min Threshold (0=off)
input int             InpMaxSpread         = 50;                // Max Spread (0=off)

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
string         g_eaName = "GoldScalpingEA";
CTrade         g_trade;
datetime       g_lastModifyTime;     // Throttle order modifications
double         g_lastBid;            // Track last bid for minimum move
double         g_lastAsk;            // Track last ask for minimum move
int            g_minMovePts = 5;     // Minimum points before modifying orders

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle");
      return(INIT_FAILED);
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   g_lastDay = dt.day;
   g_dailyLots = 0.0;
   g_dailyPnL = 0.0;

   CalcDailyStats();

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("WARNING: Algo Trading is NOT enabled! Enable it in MT5 toolbar and EA properties.");

   g_lastModifyTime = 0;
   g_lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_lastAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   Print(g_eaName, " v1.09 initialized. Magic=", InpMagicNumber, " TimeFilter=", InpTimeFilter,
         " TradeMode=", EnumToString(InpTradeMode),
         " Lot=", InpLotSize, " TrailPt=", InpBuySellTrailingPt, " SLPt=", InpStopLossTrailingPt);
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

   // --- Calculate daily P&L (only every 5 seconds to reduce load) ---
   static datetime lastStatsTime = 0;
   if(TimeCurrent() - lastStatsTime >= 5)
   {
      CalcDailyStats();
      lastStatsTime = TimeCurrent();
   }

   // --- Update chart display (only every 2 seconds) ---
   static datetime lastDisplayTime = 0;
   if(InpDisplayText && TimeCurrent() - lastDisplayTime >= 2)
   {
      UpdateDisplay();
      lastDisplayTime = TimeCurrent();
   }

   // --- Check if price has moved enough to warrant order modifications ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minMove = g_minMovePts * point;

   bool priceMovedEnough = (MathAbs(currentBid - g_lastBid) >= minMove ||
                            MathAbs(currentAsk - g_lastAsk) >= minMove);

   // --- Throttle: minimum 1 second between order modifications ---
   bool cooldownPassed = (TimeCurrent() - g_lastModifyTime >= 1);

   // --- Check filters ---
   bool filtersPass = CheckFilters();

   // --- Count open positions and pending orders ---
   int openPositions = CountPositions();
   int pendingOrders = CountPendingOrders();

   // --- Manage open positions (trailing SL) - only when price moved enough ---
   if(openPositions > 0 && priceMovedEnough && cooldownPassed)
      ManageTrailingStopLoss();

   // --- Manage pending orders (trail them) - only when price moved enough ---
   if(pendingOrders > 0 && priceMovedEnough && cooldownPassed)
      TrailPendingOrders();

   // Update last price after processing
   if(priceMovedEnough)
   {
      g_lastBid = currentBid;
      g_lastAsk = currentAsk;
   }

   // --- Place new pending orders if filters pass ---
   if(!filtersPass)
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog >= 60)
      {
         lastLog = TimeCurrent();
         Print("EA PAUSED - Filters not passing. TimeFilter=", InpTimeFilter,
               " ATR=", g_atrValue, " Threshold=", InpATRThreshold,
               " Spread=", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " MaxSpread=", InpMaxSpread);
      }
      return;
   }

   if(InpTradeMode == TRADE_MODE_SINGLE)
   {
      // Single: one pending + one position at a time
      if(openPositions == 0 && pendingOrders == 0)
      {
         int trend = DetectTrend();
         if(trend == 0)
         {
            static datetime lastTrendLog = 0;
            if(TimeCurrent() - lastTrendLog >= 60)
            {
               lastTrendLog = TimeCurrent();
               Print("No clear trend detected - waiting");
            }
         }
         PlacePendingOrder();
      }
   }
   else
   {
      // Multiple: place buy-stop AND sell-stop (bracket)
      // But only if there's no open position on that side already
      bool hasBuyStop   = HasPendingOrderType(ORDER_TYPE_BUY_STOP);
      bool hasSellStop  = HasPendingOrderType(ORDER_TYPE_SELL_STOP);
      bool hasBuyPos    = HasPositionType(POSITION_TYPE_BUY);
      bool hasSellPos   = HasPositionType(POSITION_TYPE_SELL);

      // Don't place buy-stop if already have a buy position open
      // Don't place sell-stop if already have a sell position open
      bool needBuyStop  = (!hasBuyStop && !hasBuyPos);
      bool needSellStop = (!hasSellStop && !hasSellPos);

      if(needBuyStop || needSellStop)
      {
         PlaceBracketOrders(!needBuyStop, !needSellStop);
      }
   }
}

//+------------------------------------------------------------------+
//| Check all filters                                                 |
//+------------------------------------------------------------------+
bool CheckFilters()
{
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

   if(InpATRThreshold > 0.0 && g_atrValue < InpATRThreshold)
      return false;

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
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   if(currentBid > close1 && close1 > close2)
      return 1;   // Uptrend

   if(currentBid < close1 && close1 < close2)
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
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);

      if(orderType == ORDER_TYPE_SELL_STOP)
      {
         double newPrice = NormalizeDouble(bid - trailDistance, digits);

         if(bid - newPrice < minDist)
            newPrice = NormalizeDouble(bid - minDist - point, digits);

         if(newPrice > currentPrice)
         {
            if(g_trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
            {
               Print("Sell-stop trailed up to ", newPrice);
               g_lastModifyTime = TimeCurrent();
            }
         }
      }
      else if(orderType == ORDER_TYPE_BUY_STOP)
      {
         double newPrice = NormalizeDouble(ask + trailDistance, digits);

         if(newPrice - ask < minDist)
            newPrice = NormalizeDouble(ask + minDist + point, digits);

         if(newPrice < currentPrice)
         {
            if(g_trade.OrderModify(ticket, newPrice, 0, 0, ORDER_TIME_GTC, 0))
            {
               Print("Buy-stop trailed down to ", newPrice);
               g_lastModifyTime = TimeCurrent();
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
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist    = stopsLevel * point;

   int totalPositions = PositionsTotal();
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_SELL)
      {
         double newSL = NormalizeDouble(ask + slDistance, digits);

         if(newSL - ask < minDist)
            newSL = NormalizeDouble(ask + minDist + point, digits);

         if(currentSL == 0.0 || newSL < currentSL)
         {
            // Only modify if SL change is significant (> minMovePts)
            if(currentSL == 0.0 || MathAbs(currentSL - newSL) >= g_minMovePts * point)
            {
               if(g_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Sell trailing SL moved to ", newSL);
                  g_lastModifyTime = TimeCurrent();
               }
            }
         }
      }
      else if(posType == POSITION_TYPE_BUY)
      {
         double newSL = NormalizeDouble(bid - slDistance, digits);

         if(bid - newSL < minDist)
            newSL = NormalizeDouble(bid - minDist - point, digits);

         if(currentSL == 0.0 || newSL > currentSL)
         {
            if(currentSL == 0.0 || MathAbs(newSL - currentSL) >= g_minMovePts * point)
            {
               if(g_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("Buy trailing SL moved to ", newSL);
                  g_lastModifyTime = TimeCurrent();
               }
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
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
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
      if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber &&
         OrderGetString(ORDER_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if a specific pending order type exists                     |
//+------------------------------------------------------------------+
bool HasPendingOrderType(ENUM_ORDER_TYPE checkType)
{
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(orderType == checkType)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if a specific position type exists                          |
//+------------------------------------------------------------------+
bool HasPositionType(ENUM_POSITION_TYPE checkType)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(posType == checkType)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Place bracket orders (both buy-stop and sell-stop)                |
//+------------------------------------------------------------------+
void PlaceBracketOrders(bool hasBuyStop, bool hasSellStop)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double trailDistance = InpBuySellTrailingPt * point;
   long   stopsLevel   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist      = stopsLevel * point;

   // Place BUY STOP above current price (catches upward move)
   if(!hasBuyStop)
   {
      double buyStopPrice = NormalizeDouble(ask + trailDistance, digits);

      if(buyStopPrice - ask < minDist)
         buyStopPrice = NormalizeDouble(ask + minDist + point, digits);

      if(!g_trade.BuyStop(InpLotSize, buyStopPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, g_eaName + "_BuyStop"))
         Print("BuyStop failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      else
         Print("Multi: Buy-stop placed at ", buyStopPrice);
   }

   // Place SELL STOP below current price (catches downward move)
   if(!hasSellStop)
   {
      double sellStopPrice = NormalizeDouble(bid - trailDistance, digits);

      if(bid - sellStopPrice < minDist)
         sellStopPrice = NormalizeDouble(bid - minDist - point, digits);

      if(!g_trade.SellStop(InpLotSize, sellStopPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, g_eaName + "_SellStop"))
         Print("SellStop failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      else
         Print("Multi: Sell-stop placed at ", sellStopPrice);
   }
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

         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagicNumber &&
            HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

            // Count lots only for entries (not exits, to avoid double counting)
            if(entry == DEAL_ENTRY_IN)
               g_dailyLots += HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

            // Count P&L from both entries and exits
            if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_OUT)
            {
               g_dailyPnL  += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                            + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                            + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
            }
         }
      }
   }

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         g_dailyPnL += PositionGetDouble(POSITION_PROFIT)
                     + PositionGetDouble(POSITION_SWAP);
      }
   }
}

//+------------------------------------------------------------------+
//| Update on-chart display - compact top-right corner                |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int    atrDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool   active = CheckFilters();
   string mode = (InpTradeMode == TRADE_MODE_SINGLE) ? "Single" : "Multiple";

   int xPos = 10;
   int yPos = 20;
   int yStep = 16;
   int fontSize = 9;
   string fontName = "Consolas";
   color textColor = clrWhite;

   // All labels anchored to TOP-RIGHT corner
   CreateLabel("GSE_Header", g_eaName, xPos, yPos, clrGold, 10, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep + 2;

   CreateLabel("GSE_Equity", "Equity:    " + DoubleToString(equity, 2), xPos, yPos, textColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   CreateLabel("GSE_Lots", "Lots:      " + DoubleToString(g_dailyLots, 2), xPos, yPos, textColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   color pnlColor = (g_dailyPnL >= 0) ? clrLime : clrRed;
   CreateLabel("GSE_PnL", "P/L:       " + DoubleToString(g_dailyPnL, 2), xPos, yPos, pnlColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   CreateLabel("GSE_ATR", "ATR:       " + DoubleToString(g_atrValue, atrDigits), xPos, yPos, textColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   CreateLabel("GSE_Slip", "Slippage:  " + IntegerToString(InpSlippage), xPos, yPos, textColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   color spreadColor = (InpMaxSpread > 0 && spread > InpMaxSpread) ? clrRed : textColor;
   CreateLabel("GSE_Spread", "Spread:    " + IntegerToString(spread), xPos, yPos, spreadColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   color statusColor = active ? clrLime : clrOrangeRed;
   string status = active ? "ACTIVE" : "PAUSED";
   CreateLabel("GSE_Status", "Status:    " + status, xPos, yPos, statusColor, fontSize, fontName, CORNER_RIGHT_UPPER);
   yPos += yStep;

   CreateLabel("GSE_Mode", "Mode:      " + mode, xPos, yPos, clrGold, fontSize, fontName, CORNER_RIGHT_UPPER);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create or update a text label on chart                            |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int size, string font,
                 ENUM_BASE_CORNER corner = CORNER_RIGHT_UPPER)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
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
