//+------------------------------------------------------------------+
//|                     MT5_SL_TP_R_Display.mq5                      |
//|                                                                  |
//| 功能：                                                           |
//| 1. 当前品种持仓 SL 右侧显示亏损金额                              |
//| 2. 当前品种持仓 TP 右侧显示盈利金额                              |
//| 3. 根据 Entry -> SL 自动计算 1R / 3R / 5R                       |
//| 4. 1R / 3R / 5R 独立开关                                        |
//| 5. 自动识别多单 / 空单                                           |
//| 6. 支持多个持仓                                                 |
//| 7. SL / TP 修改后自动更新                                       |
//| 8. R 倍数以独立小横线显示                                        |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//====================================================================
// 参数
//====================================================================

input group "===== SL / TP ====="

input bool   InpShowSL = true;                  // 显示 SL
input bool   InpShowTP = true;                  // 显示 TP

input color  InpSLColor = clrRed;               // SL 颜色
input color  InpTPColor = clrLimeGreen;         // TP 颜色

input int    InpSLTPFontSize = 9;               // SL/TP 字体大小
input string InpSLTPFont = "Arial";             // SL/TP 字体


input group "===== 挂单 ====="

input bool   InpShowPending = true;             // 显示挂单 SL / TP 金额
input bool   InpShowPendingEntry = true;        // 显示挂单入场价与手数
input bool   InpShowPendingR = true;            // 挂单也画 1R / 3R / 5R
input color  InpPendingColor = clrDodgerBlue;   // 挂单标签颜色
input color  InpPendingLineColor = clrAqua;     // 挂单入场价线颜色
input bool   InpShowPendingEntryLine = true;    // 画挂单入场价横线


input group "===== 盈亏比 ====="

input bool   InpShow1R = true;                  // 显示 1R
input bool   InpShow3R = true;                  // 显示 3R
input bool   InpShow5R = true;                  // 显示 5R

input color  InpRColor = clrGold;               // R 线颜色
input int    InpRLineWidth = 1;                 // R 线宽度
input ENUM_LINE_STYLE InpRLineStyle = STYLE_SOLID;

// 小横线长度
input int    InpRLineLength = 35;

// 右侧距离
input int    InpRightDistance = 5;


//====================================================================
// 对象名称
//====================================================================

string PREFIX = "MT5_RISK_DISPLAY_";


//====================================================================
// 初始化
//====================================================================

int OnInit()
  {
   EventSetTimer(1);

   UpdateAll();

   return(INIT_SUCCEEDED);
  }


//====================================================================
// 反初始化
//====================================================================

void OnDeinit(const int reason)
  {
   EventKillTimer();

   DeleteAllObjects();

   ChartRedraw();
  }


//====================================================================
// Timer
//====================================================================

void OnTimer()
  {
   UpdateAll();

   ChartRedraw();
  }


//====================================================================
// OnCalculate
//====================================================================

int OnCalculate(
   const int rates_total,
   const int prev_calculated,
   const datetime &time[],
   const double &open[],
   const double &high[],
   const double &low[],
   const double &close[],
   const long &tick_volume[],
   const long &volume[],
   const int &spread[])
  {
   return(rates_total);
  }


//====================================================================
// 更新所有持仓
//====================================================================

void UpdateAll()
  {
   DeleteAllObjects();

   DrawPositions();

   DrawPendingOrders();
  }


//====================================================================
// 绘制持仓
//====================================================================

void DrawPositions()
  {
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      // 只显示当前图表品种
      if(symbol != _Symbol)
         continue;


      double entry =
         PositionGetDouble(POSITION_PRICE_OPEN);

      double sl =
         PositionGetDouble(POSITION_SL);

      double tp =
         PositionGetDouble(POSITION_TP);

      double volume =
         PositionGetDouble(POSITION_VOLUME);

      long positionType =
         PositionGetInteger(POSITION_TYPE);


      //==============================================================
      // SL
      //==============================================================

      if(InpShowSL && sl > 0)
        {
         double slMoney =
            CalculateMoney(
               entry,
               sl,
               volume);

         CreatePriceLabel(
            "SL_" + IntegerToString((long)ticket),
            sl,
            "SL  -$" + DoubleToString(slMoney, 2),
            InpSLColor);
        }


      //==============================================================
      // TP
      //==============================================================

      if(InpShowTP && tp > 0)
        {
         double tpMoney =
            CalculateMoney(
               entry,
               tp,
               volume);

         CreatePriceLabel(
            "TP_" + IntegerToString((long)ticket),
            tp,
            "TP  +$" + DoubleToString(tpMoney, 2),
            InpTPColor);
        }


      //==============================================================
      // 必须有 SL 才能计算 R
      //==============================================================

      if(sl <= 0)
         continue;


      //==============================================================
      // 计算 1R / 3R / 5R
      //==============================================================

      double riskDistance =
         MathAbs(entry - sl);


      double price1R;
      double price3R;
      double price5R;


      //==============================================================
      // 多单
      //==============================================================

      if(positionType == POSITION_TYPE_BUY)
        {
         price1R =
            entry + riskDistance;

         price3R =
            entry + riskDistance * 3.0;

         price5R =
            entry + riskDistance * 5.0;
        }


      //==============================================================
      // 空单
      //==============================================================

      else
        {
         price1R =
            entry - riskDistance;

         price3R =
            entry - riskDistance * 3.0;

         price5R =
            entry - riskDistance * 5.0;
        }


      //==============================================================
      // 1R
      //==============================================================

      if(InpShow1R)
        {
         CreateRLine(
            "1R_" + IntegerToString((long)ticket),
            price1R,
            "1R",
            InpRColor);
        }


      //==============================================================
      // 3R
      //==============================================================

      if(InpShow3R)
        {
         CreateRLine(
            "3R_" + IntegerToString((long)ticket),
            price3R,
            "3R",
            InpRColor);
        }


      //==============================================================
      // 5R
      //==============================================================

      if(InpShow5R)
        {
         CreateRLine(
            "5R_" + IntegerToString((long)ticket),
            price5R,
            "5R",
            InpRColor);
        }
     }
  }


//====================================================================
// 挂单方向判断
//====================================================================

bool IsLongOrderType(const long orderType)
  {
   if(orderType == ORDER_TYPE_BUY)
      return(true);

   if(orderType == ORDER_TYPE_BUY_LIMIT)
      return(true);

   if(orderType == ORDER_TYPE_BUY_STOP)
      return(true);

   if(orderType == ORDER_TYPE_BUY_STOP_LIMIT)
      return(true);

   return(false);
  }


//====================================================================
// 挂单类型文字
//====================================================================

string OrderTypeText(const long orderType)
  {
   if(orderType == ORDER_TYPE_BUY_LIMIT)
      return("BUY LIMIT");

   if(orderType == ORDER_TYPE_SELL_LIMIT)
      return("SELL LIMIT");

   if(orderType == ORDER_TYPE_BUY_STOP)
      return("BUY STOP");

   if(orderType == ORDER_TYPE_SELL_STOP)
      return("SELL STOP");

   if(orderType == ORDER_TYPE_BUY_STOP_LIMIT)
      return("BUY STOP LIMIT");

   if(orderType == ORDER_TYPE_SELL_STOP_LIMIT)
      return("SELL STOP LIMIT");

   return("ORDER");
  }


//====================================================================
// 绘制挂单：入场价 / SL 金额 / TP 金额 / R 倍数
//====================================================================

void DrawPendingOrders()
  {
   if(!InpShowPending && !InpShowPendingEntry)
      return;

   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
     {
      ulong ticket = OrderGetTicket(i);

      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      string symbol =
         OrderGetString(ORDER_SYMBOL);

      // 只显示当前图表品种
      if(symbol != _Symbol)
         continue;


      double entry =
         OrderGetDouble(ORDER_PRICE_OPEN);

      double sl =
         OrderGetDouble(ORDER_SL);

      double tp =
         OrderGetDouble(ORDER_TP);

      double volume =
         OrderGetDouble(ORDER_VOLUME_CURRENT);

      if(volume <= 0)
         volume =
            OrderGetDouble(ORDER_VOLUME_INITIAL);

      long orderType =
         OrderGetInteger(ORDER_TYPE);

      int digits =
         (int)SymbolInfoInteger(
            _Symbol,
            SYMBOL_DIGITS);

      string suffix =
         IntegerToString((long)ticket);


      //==============================================================
      // 入场价与手数
      //==============================================================

      if(InpShowPendingEntry && entry > 0)
        {
         string entryText =
            OrderTypeText(orderType) +
            "  " + DoubleToString(entry, digits) +
            "  " + DoubleToString(volume, 2) + "手";

         CreatePriceLabel(
            "OENTRY_" + suffix,
            entry,
            entryText,
            InpPendingColor);

         if(InpShowPendingEntryLine)
            CreateRLine(
               "OENTRYLINE_" + suffix,
               entry,
               "",
               InpPendingLineColor);
        }


      if(!InpShowPending)
         continue;


      //==============================================================
      // SL 金额
      //==============================================================

      if(sl > 0)
        {
         double slMoney =
            CalculateMoney(
               entry,
               sl,
               volume);

         CreatePriceLabel(
            "OSL_" + suffix,
            sl,
            "SL  -$" + DoubleToString(slMoney, 2),
            InpSLColor);
        }


      //==============================================================
      // TP 金额
      //==============================================================

      if(tp > 0)
        {
         double tpMoney =
            CalculateMoney(
               entry,
               tp,
               volume);

         CreatePriceLabel(
            "OTP_" + suffix,
            tp,
            "TP  +$" + DoubleToString(tpMoney, 2),
            InpTPColor);
        }


      //==============================================================
      // R 倍数（必须有 SL）
      //==============================================================

      if(!InpShowPendingR)
         continue;

      if(sl <= 0 || entry <= 0)
         continue;


      double riskDistance =
         MathAbs(entry - sl);


      double price1R;
      double price3R;
      double price5R;


      if(IsLongOrderType(orderType))
        {
         price1R =
            entry + riskDistance;

         price3R =
            entry + riskDistance * 3.0;

         price5R =
            entry + riskDistance * 5.0;
        }
      else
        {
         price1R =
            entry - riskDistance;

         price3R =
            entry - riskDistance * 3.0;

         price5R =
            entry - riskDistance * 5.0;
        }


      if(InpShow1R)
         CreateRLine(
            "O1R_" + suffix,
            price1R,
            "1R",
            InpRColor);

      if(InpShow3R)
         CreateRLine(
            "O3R_" + suffix,
            price3R,
            "3R",
            InpRColor);

      if(InpShow5R)
         CreateRLine(
            "O5R_" + suffix,
            price5R,
            "5R",
            InpRColor);
     }
  }


//====================================================================
// 计算金额
//====================================================================

double CalculateMoney(
   double entry,
   double target,
   double volume)
  {
   double distance =
      MathAbs(target - entry);


   double tickSize =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_SIZE);


   double tickValue =
      SymbolInfoDouble(
         _Symbol,
         SYMBOL_TRADE_TICK_VALUE);


   if(tickSize <= 0 || tickValue <= 0)
      return(0);


   double money =
      distance /
      tickSize *
      tickValue *
      volume;


   return(MathAbs(money));
  }


//====================================================================
// 创建 SL / TP 标签
//====================================================================

void CreatePriceLabel(
   string name,
   double price,
   string text,
   color textColor)
  {
   string objectName =
      PREFIX + name;


   //==============================================================
   // 创建对象
   //==============================================================

   if(ObjectFind(0, objectName) == -1)
     {
      ObjectCreate(
         0,
         objectName,
         OBJ_TEXT,
         0,
         0,
         price);
     }


   //==============================================================
   // 根据当前价格转换到屏幕坐标
   //==============================================================

   int x = 0;
   int y = 0;


   datetime rightTime =
      GetRightTime();


   if(!ChartTimePriceToXY(
         0,
         0,
         rightTime,
         price,
         x,
         y))
      return;


   //==============================================================
   // 设置文本
   //==============================================================

   ObjectSetString(
      0,
      objectName,
      OBJPROP_TEXT,
      text);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_COLOR,
      textColor);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_FONTSIZE,
      InpSLTPFontSize);


   ObjectSetString(
      0,
      objectName,
      OBJPROP_FONT,
      InpSLTPFont);


   //==============================================================
   // 直接使用时间/价格坐标
   //==============================================================

   ObjectMove(
      0,
      objectName,
      0,
      rightTime,
      price);


   //==============================================================
   // 锚点
   //==============================================================

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_ANCHOR,
      ANCHOR_RIGHT);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTABLE,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTED,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_HIDDEN,
      true);
  }


//====================================================================
// 创建 R 小横线
//====================================================================

void CreateRLine(
   string name,
   double price,
   string text,
   color lineColor)
  {
   string objectName =
      PREFIX + name;


   //==============================================================
   // 当前图表可见时间范围
   //==============================================================

   datetime rightTime =
      GetRightTime();


   datetime leftTime =
      GetRLeftTime();


   //==============================================================
   // 创建趋势线
   //==============================================================

   if(ObjectFind(0, objectName) == -1)
     {
      ObjectCreate(
         0,
         objectName,
         OBJ_TREND,
         0,
         leftTime,
         price,
         rightTime,
         price);
     }
   else
     {
      ObjectMove(
         0,
         objectName,
         0,
         leftTime,
         price);

      ObjectMove(
         0,
         objectName,
         1,
         rightTime,
         price);
     }


   //==============================================================
   // 线属性
   //==============================================================

   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_COLOR,
      lineColor);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_WIDTH,
      InpRLineWidth);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_STYLE,
      InpRLineStyle);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_RAY_LEFT,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_RAY_RIGHT,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTABLE,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_SELECTED,
      false);


   ObjectSetInteger(
      0,
      objectName,
      OBJPROP_HIDDEN,
      true);


   //==============================================================
   // 创建 R 标签
   //==============================================================

   string labelName =
      objectName + "_LABEL";


   if(ObjectFind(0, labelName) == -1)
     {
      ObjectCreate(
         0,
         labelName,
         OBJ_TEXT,
         0,
         rightTime,
         price);
     }


   ObjectMove(
      0,
      labelName,
      0,
      rightTime,
      price);


   ObjectSetString(
      0,
      labelName,
      OBJPROP_TEXT,
      text);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_COLOR,
      lineColor);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_FONTSIZE,
      InpSLTPFontSize);


   ObjectSetString(
      0,
      labelName,
      OBJPROP_FONT,
      InpSLTPFont);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_ANCHOR,
      ANCHOR_RIGHT);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_SELECTABLE,
      false);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_SELECTED,
      false);


   ObjectSetInteger(
      0,
      labelName,
      OBJPROP_HIDDEN,
      true);
  }


//====================================================================
// 获取图表右侧时间
//====================================================================

datetime GetRightTime()
  {
   long firstVisible =
      ChartGetInteger(
         0,
         CHART_FIRST_VISIBLE_BAR,
         0);


   long visibleBars =
      ChartGetInteger(
         0,
         CHART_VISIBLE_BARS,
         0);


   if(firstVisible < 0)
      return(TimeCurrent());


   datetime currentBarTime =
      iTime(
         _Symbol,
         _Period,
         0);


   int periodSeconds =
      PeriodSeconds(_Period);


   if(periodSeconds <= 0)
      periodSeconds = 60;


   // 给右侧留出空间
   datetime rightTime =
      currentBarTime +
      periodSeconds * 5;


   return(rightTime);
  }


//====================================================================
// 获取 R 横线左端
//====================================================================

datetime GetRLeftTime()
  {
   datetime rightTime =
      GetRightTime();


   int periodSeconds =
      PeriodSeconds(_Period);


   if(periodSeconds <= 0)
      periodSeconds = 60;


   // 根据周期长度决定小横线长度
   int barsLength = 3;


   datetime leftTime =
      rightTime -
      periodSeconds * barsLength;


   return(leftTime);
  }


//====================================================================
// 删除所有对象
//====================================================================

void DeleteAllObjects()
  {
   int total =
      ObjectsTotal(0);


   for(int i = total - 1; i >= 0; i--)
     {
      string name =
         ObjectName(0, i);


      if(StringFind(
            name,
            PREFIX) == 0)
        {
         ObjectDelete(
            0,
            name);
        }
     }
  }

//+------------------------------------------------------------------+