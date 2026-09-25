//+------------------------------------------------------------------+
//|                                             pa_signal_bridge.mq5  |
//|        PA Agent -> MT5 信号桥：读 JSON 信号文件 -> 面板 -> 下单    |
//|                                                                  |
//| 工作原理（为什么是「轮询文件」而不是「接收推送」）                  |
//|   MQL5 的 WebRequest() 只能由 EA 主动向外发起请求，EA 本身无法监听 |
//|   端口，也不能作为 HTTP 服务端。所以「PA Agent 直接推给 MT5」在纯   |
//|   MQL5 里做不到，只能让 PA Agent 把信号落成文件、EA 定时去取。      |
//|                                                                  |
//| 目录                                                              |
//|   公共目录（FILE_COMMON）:                                        |
//|     <TERMINAL_COMMONDATA_PATH>\Files\PA_Agent\signals\            |
//|   例如:                                                           |
//|     C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\Common\      |
//|       Files\PA_Agent\signals\signal_20260923_105700_XAUUSDm.json  |
//|   面板顶部会显示解析出来的真实绝对路径，照着往里放文件即可。        |
//|                                                                  |
//| 信号文件契约（JSON，UTF-8，*.json，文件名建议按时间字典序）         |
//|   {                                                               |
//|     "id":        "20260923T105700_XAUUSDm_15m",  // 唯一，用于去重 |
//|     "symbol":    "XAUUSDm",                                       |
//|     "timeframe": "15m",                                           |
//|     "order_type": "市价单",      // 市价单/限价单/突破单/止损单/不下单
//|                                  // 也认 MARKET / LIMIT / STOP / NONE
//|     "order_direction": "做多",   // 做多 / 做空（buy/sell/long/short）
//|     "entry_price":        3850.5,                                 |
//|     "stop_loss_price":    3845.0,                                 |
//|     "take_profit_price":  3860.0,                                 |
//|     "take_profit_price_2":3870.0,   // 可选                       |
//|     "volume":            0.01,      // 可选，缺省用 InpLot         |
//|     "trade_confidence":  0.78,      // 可选，仅展示               |
//|     "estimated_win_rate":62,        // 可选，仅展示               |
//|     "created_at":        1789922220,// 可选，UTC epoch 秒，判过期  |
//|     "reasoning":         "……"       // 可选，仅展示               |
//|   }                                                               |
//|                                                                  |
//| 去重与消费                                                        |
//|   处理过的文件名写入 PA_Agent\signal_bridge_state.txt，重启 EA 不会|
//|   重复下单；[清空状态] 会让它重新读取全部历史文件（谨慎）。        |
//|                                                                  |
//| 面板按钮                                                          |
//|   [立即扫描]     不等定时器，马上扫一次                           |
//|   [写测试信号]   在当前目录生成一个示例 JSON，用来验证整条链路     |
//|   [清空状态]     清空已处理记录 + 面板缓存                        |
//+------------------------------------------------------------------+
#property copyright "PA Agent"
#property version   "1.00"
#property description "PA Agent 信号桥：轮询公共目录中的 JSON 信号，面板显示并可自动下单。"

//--- Inputs ---------------------------------------------------------
input group "SIGNAL"
input string InpSignalFolder       = "PA_Agent\\signals"; // 信号目录（相对公共 Files）
input string InpStateFile          = "PA_Agent\\signal_bridge_state.txt"; // 已处理记录
input int    InpPollSeconds        = 2;      // 轮询间隔（秒，最小 1）
input bool   InpScanOnInit         = true;   // 加载时立刻扫描一次
input bool   InpOnlyCurrentSymbol  = true;   // 只处理当前图表品种的信号
input int    InpMaxSignalAgeSec    = 1800;   // 信号最长有效期（秒，0 = 不限制）
input bool   InpDeleteAfterProcess = false;  // 处理后删除信号文件
input int    InpMaxFilesPerScan    = 10;     // 单次扫描最多处理的文件数
input int    InpMaxJsonChars       = 400;    // 面板显示原始 JSON 的最大字符数

input group "TRADE"
input bool   InpAutoTrade          = false;  // 自动下单（false = 只看不交易）
input double InpLot                = 0.01;   // 默认手数
input bool   InpUseSignalVolume    = true;   // 优先使用信号里的 volume
input int    InpMagic              = 20260923; // Magic number
input int    InpDeviation          = 20;     // 市价单允许偏差（point）
input bool   InpSplitTP2           = false;  // TP1 / TP2 拆成两笔单
input string InpComment            = "PA_Agent"; // 订单注释
input bool   InpCheckStopsLevel    = true;   // 检查止损/止盈最小距离
input bool   InpFixStopsLevel      = false;  // 自动放宽过近的 SL/TP（默认否）

//--- 以损订仓：按止损距离与可承受风险反推手数（AI 不输出手数，仓位永远由本 EA 决定）
input bool   InpRiskBasedLot       = false;  // 启用以损订仓（无止损时回退固定手数）
input double InpRiskAmount         = 0.0;    // 每笔风险金额（账户货币；0 = 改用 InpRiskPercent）
input double InpRiskPercent        = 1.0;    // 每笔风险占净值百分比（InpRiskAmount=0 时生效）
input double InpRiskMaxLot         = 0.0;    // 以损订仓手数上限（0 = 用品种上限）

//--- 一键下单方式（面板按钮使用）
enum ENUM_QUICK_MODE
  {
   QUICK_MARKET = 0, // 市价单
   QUICK_LIMIT  = 1, // 限价挂单（回踩接）
   QUICK_STOP   = 2  // 突破挂单
  };

input group "QUICK"
input ENUM_QUICK_MODE InpQuickMode = QUICK_MARKET; // 一键下单方式
input int    InpQuickDistance = 100;    // 挂单距市价（point，市价单忽略）
input int    InpQuickSLPoints = 200;    // 止损距离（point）
input int    InpQuickTPPoints = 0;      // 止盈距离（point，0 = 与止损相同即 1:1）
input double InpQuickLot      = 0.0;    // 一键下单手数（0 = 用 InpLot）
input bool   InpQuickOnlyCurrentSymbol = true; // 全部平仓只平当前品种

input group "PROFIT GUARD（盈利保护·实时移动止损）"
input bool   InpProfitGuard       = true;   // 启用盈利保护
input double InpBEStepPct         = 50.0;   // 盈利达目标的多少%→保本（0=关闭保本）
input double InpLockTriggerPct    = 85.0;   // 盈利达目标的多少%→启动锁利
input double InpLockProfitPct     = 50.0;   // 锁利比例：止损位=入场±该比例×当前盈利
input bool   InpGuardOnlyMyMagic  = true;   // 只管理本 EA(magic) 开的仓
input bool   InpGuardOnlyCurrentSymbol = true; // 只管理当前图表品种
input bool   InpGuardRespectStopsLevel = true; // 锁利位离市价过近时自动放宽

input group "PANEL"
input ENUM_BASE_CORNER InpCorner   = CORNER_LEFT_UPPER; // Panel corner
input int    InpPanelX             = 10;     // Panel X offset
input int    InpPanelY             = 30;     // Panel Y offset
input int    InpPanelWidth         = 520;    // Panel width (pixels)
input int    InpLineHeight         = 14;     // Line height (pixels)
input int    InpCharsPerLine       = 76;     // Characters per line before wrapping
input int    InpFontSize           = 9;      // Font size
input string InpFontName           = "Consolas"; // Font
input color  InpBackColor          = C'16,20,26';    // Panel background
input color  InpBorderColor        = C'70,84,100';   // Panel border
input color  InpTextColor          = C'220,225,232'; // Normal text
input color  InpTitleColor         = C'90,180,255';  // Title / section text
input color  InpOkColor            = C'70,220,130';  // Success text
input color  InpFailColor          = C'255,95,95';   // Failure text
input color  InpWarnColor          = C'255,200,90';  // Warning text

//--- Object names ---------------------------------------------------
#define SB_BG        "SB_PANEL_BG"
#define SB_BTN_SCAN  "SB_BTN_SCAN"
#define SB_BTN_TEST  "SB_BTN_TEST"
#define SB_BTN_CLEAR "SB_BTN_CLEAR"
#define SB_BTN_BUY   "SB_BTN_BUY"
#define SB_BTN_SELL  "SB_BTN_SELL"
#define SB_BTN_CLOSE "SB_BTN_CLOSE"
#define SB_LINE_PFX  "SB_LINE_"

//--- Panel line buffer ----------------------------------------------
struct PanelLine
  {
   string text; // Line content
   color  clr;  // Line colour
  };

PanelLine g_lines[];         // Lines of the current render
int       g_drawnLines = 0;  // Lines drawn by the previous render

//--- One signal read from disk --------------------------------------
struct SignalData
  {
   string fileName;   // File the signal came from
   string id;         // Unique id (dedup + display)
   string symbol;     // Symbol
   string timeframe;  // Timeframe label
   string orderType;  // 市价单 / 限价单 / 突破单 / 止损单 / 不下单
   string direction;  // 做多 / 做空
   double entry;      // Entry price
   double sl;         // Stop loss
   double tp1;        // Take profit 1
   double tp2;        // Take profit 2 (0 = absent)
   double volume;     // Requested volume (0 = absent)
   double confidence; // Trade confidence (0 = absent)
   double winrate;    // Estimated win rate (0 = absent)
   long   createdAt;  // UTC epoch seconds (0 = absent)
   string reasoning;  // Reasoning text
  };

//--- Outcome of the last execution attempt --------------------------
struct ExecResult
  {
   bool     attempted; // True once an execution was attempted
   datetime at;        // When
   int      retcode;   // Trade server return code (0 = nothing sent)
   ulong    order;     // Order ticket
   ulong    deal;      // Deal ticket
   double   price;     // Filled / placed price
   double   volume;    // Filled / placed volume
   string   note;      // Human readable outcome
   bool     ok;        // True when the request succeeded
  };

SignalData  g_sig;          // Last signal seen
ExecResult  g_exec;         // Last execution result
string      g_raw     = ""; // Raw JSON of the last signal
bool        g_hasSig  = false;
string      g_done[];       // Already processed file names
string      g_dirNote = ""; // Note about the signal folder
int         g_pending = 0;  // Files waiting to be processed
int         g_scans   = 0;  // Number of scans performed
datetime    g_lastScan = 0; // Time of the last scan
datetime    g_lastGuard = 0; // Last profit-guard modification time (throttle)

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Load the already-processed list
   LoadState();
   //--- Draw the panel for the first time
   RefreshPanel();
   //--- Look for signals right away when requested
   if(InpScanOnInit) ScanOnce();
   RefreshPanel();
   //--- Poll the folder on a timer
   int seconds = InpPollSeconds;
   if(seconds < 1) seconds = 1;
   EventSetTimer(seconds);
   //--- Report a successful init
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Stop the timer
   EventKillTimer();
   //--- Remove every object owned by this panel
   ObjectsDeleteAll(0, "SB_");
   //--- Repaint the chart
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Timer: poll the signal folder                                    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   //--- Read new files, then repaint
   ScanOnce();
   GuardPositions();
   RefreshPanel();
  }

//+------------------------------------------------------------------+
//| Ticks are not needed, but keep the chart fresh                   |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Real-time profit protection runs on every tick
   GuardPositions();
  }

//+------------------------------------------------------------------+
//| Button clicks                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   //--- Only button clicks matter here
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   //--- Scan now
   if(sparam == SB_BTN_SCAN)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ScanOnce();
      RefreshPanel();
      return;
     }
   //--- Write a sample signal file
   if(sparam == SB_BTN_TEST)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      WriteTestSignal();
      RefreshPanel();
      return;
     }
   //--- One-click buy
   if(sparam == SB_BTN_BUY)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      PlaceQuickOrder(1);
      RefreshPanel();
      return;
     }
   //--- One-click sell
   if(sparam == SB_BTN_SELL)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      PlaceQuickOrder(-1);
      RefreshPanel();
      return;
     }
   //--- Close every position
   if(sparam == SB_BTN_CLOSE)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      CloseAllNow();
      RefreshPanel();
      return;
     }
   //--- Forget everything
   if(sparam == SB_BTN_CLEAR)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ClearEverything();
      RefreshPanel();
      return;
     }
  }

//+------------------------------------------------------------------+
//| Forget every cached result                                       |
//+------------------------------------------------------------------+
void ClearEverything()
  {
   //--- Drop the processed list and its file
   ArrayResize(g_done, 0);
   FileDelete(InpStateFile, FILE_COMMON);
   //--- Reset the cached signal
   g_hasSig       = false;
   g_sig.fileName = "";
   g_sig.id       = "";
   g_raw          = "";
   //--- Reset the cached outcome
   g_exec.attempted = false;
   g_exec.at        = 0;
   g_exec.retcode   = 0;
   g_exec.order     = 0;
   g_exec.deal      = 0;
   g_exec.price     = 0.0;
   g_exec.volume    = 0.0;
   g_exec.ok        = false;
   g_exec.note      = "已清空：历史文件会被重新读取（自动下单开启时可能重复下单）";
   //--- Look again right away so the panel is not empty
   ScanOnce();
  }
//+------------------------------------------------------------------+
//| Append one line to the panel buffer (internal)                   |
//+------------------------------------------------------------------+
void AddPanelLine(const string text, const color clr)
  {
   //--- Grow the buffer by one line
   int n = ArraySize(g_lines);
   ArrayResize(g_lines, n + 1);
   g_lines[n].text = text;
   g_lines[n].clr  = clr;
  }

//+------------------------------------------------------------------+
//| Append text, splitting on newlines and wrapping long lines       |
//+------------------------------------------------------------------+
void AddWrapped(const string text, const color clr)
  {
   //--- Split the source text on explicit line breaks
   string segments[];
   int count = StringSplit(text, '\n', segments);
   //--- Handle the empty-text case
   if(count <= 0)
     {
      AddPanelLine("", clr);
      return;
     }
   //--- Work through every segment
   int width = (int)MathMax(16.0, (double)InpCharsPerLine);
   for(int s = 0; s < count; s++)
     {
      //--- Read one segment
      string segment = segments[s];
      int    length  = StringLen(segment);
      //--- Keep blank lines as separators
      if(length == 0)
        {
         AddPanelLine("", clr);
         continue;
        }
      //--- Cut the segment into screen-width chunks
      for(int pos = 0; pos < length; pos += width)
         AddPanelLine(StringSubstr(segment, pos, width), clr);
     }
  }

//+------------------------------------------------------------------+
//| Truncate a long text so the panel stays readable                 |
//+------------------------------------------------------------------+
string TruncateText(const string text, const int maxChars)
  {
   //--- Leave short texts untouched
   if(maxChars <= 0 || StringLen(text) <= maxChars) return text;
   //--- Cut and mark the truncation
   return StringSubstr(text, 0, maxChars) + " …(截断)";
  }

//+------------------------------------------------------------------+
//| Current timeframe as a short label (M15, H1, ...)                |
//+------------------------------------------------------------------+
string TimeframeText()
  {
   //--- Strip the PERIOD_ prefix from the enum name
   string tf = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(tf, "PERIOD_", "");
   return tf;
  }

//+------------------------------------------------------------------+
//| Absolute path of the MT5 "common" files sandbox                  |
//+------------------------------------------------------------------+
string CommonFilesPath()
  {
   return TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files";
  }

//+------------------------------------------------------------------+
//| Absolute path of the folder this EA polls                        |
//+------------------------------------------------------------------+
string SignalFolderPath()
  {
   return CommonFilesPath() + "\\" + InpSignalFolder;
  }

//+------------------------------------------------------------------+
//| Convert a string into UTF-8 bytes (terminating zero removed)     |
//+------------------------------------------------------------------+
void Utf8Bytes(const string text, char &bytes[])
  {
   //--- Convert with the UTF-8 code page
   char raw[];
   int copied = StringToCharArray(text, raw, 0, WHOLE_ARRAY, CP_UTF8);
   //--- Ignore a failed conversion
   if(copied < 0) copied = 0;
   //--- Drop the terminating zero added by the conversion
   if(copied > 0 && raw[copied - 1] == 0) copied--;
   //--- Copy the bytes into the output buffer
   ArrayResize(bytes, copied);
   for(int i = 0; i < copied; i++) bytes[i] = raw[i];
  }

//+------------------------------------------------------------------+
//| Escape a string so it can be embedded in a JSON string           |
//+------------------------------------------------------------------+
string JsonEscape(const string text)
  {
   //--- Walk every character of the source text
   string out = "";
   int len = StringLen(text);
   for(int i = 0; i < len; i++)
     {
      //--- Read one UTF-16 code unit
      ushort code = StringGetCharacter(text, i);
      switch(code)
        {
         case 34: out += "\\\""; break; // double quote
         case 92: out += "\\\\"; break; // backslash
         case 10: out += "\\n";  break; // line feed
         case 13: out += "\\r";  break; // carriage return
         case 9:  out += "\\t";  break; // tab
         case 8:  out += "\\b";  break; // backspace
         case 12: out += "\\f";  break; // form feed
         default:
            //--- Escape the remaining control characters numerically
            if(code < 32) out += StringFormat("\\u%04x", code);
            else          out += ShortToString(code);
            break;
        }
     }
   //--- Return the escaped text
   return out;
  }

//+------------------------------------------------------------------+
//| Value of one hexadecimal digit (-1 when invalid)                 |
//+------------------------------------------------------------------+
int HexDigit(const ushort c)
  {
   if(c >= '0' && c <= '9') return (int)(c - '0');
   if(c >= 'a' && c <= 'f') return (int)(c - 'a') + 10;
   if(c >= 'A' && c <= 'F') return (int)(c - 'A') + 10;
   return -1;
  }

//+------------------------------------------------------------------+
//| Read the value of a string JSON field (small UTF-8 aware parser) |
//+------------------------------------------------------------------+
string JsonStringText(const string json, const string field)
  {
   //--- Locate the field name
   string needle = "\"" + field + "\"";
   int pos = StringFind(json, needle);
   if(pos < 0) return "";
   //--- Skip the name, the colon and any spaces
   int i = pos + StringLen(needle);
   while(i < StringLen(json) && (StringGetCharacter(json, i) == ':' || StringGetCharacter(json, i) == ' ')) i++;
   //--- Only string values are handled here
   if(i >= StringLen(json) || StringGetCharacter(json, i) != '"') return "";
   i++;
   //--- Collect characters up to the closing quote
   string out = "";
   while(i < StringLen(json))
     {
      //--- Read one code unit
      ushort code = StringGetCharacter(json, i);
      if(code == '"') break;
      //--- Undo the escapes JSON allows
      if(code == 92 && i + 1 < StringLen(json))
        {
         ushort next = StringGetCharacter(json, i + 1);
         if(next == 'n')  { out += "\n"; i += 2; continue; }
         if(next == 't')  { out += "\t"; i += 2; continue; }
         if(next == 'r')  { out += "\r"; i += 2; continue; }
         if(next == '"')  { out += "\""; i += 2; continue; }
         if(next == 92)   { out += "\\"; i += 2; continue; }
         if(next == '/')  { out += "/";  i += 2; continue; }
         //--- \uXXXX, surrogate pairs included so emoji and rare CJK survive
         if(next == 'u' && i + 5 < StringLen(json))
           {
            int h1 = HexDigit(StringGetCharacter(json, i + 2));
            int h2 = HexDigit(StringGetCharacter(json, i + 3));
            int h3 = HexDigit(StringGetCharacter(json, i + 4));
            int h4 = HexDigit(StringGetCharacter(json, i + 5));
            if(h1 >= 0 && h2 >= 0 && h3 >= 0 && h4 >= 0)
              {
               int value = h1 * 4096 + h2 * 256 + h3 * 16 + h4;
               //--- High surrogate followed by a low one?
               if(value >= 0xD800 && value <= 0xDBFF && i + 11 < StringLen(json) &&
                  StringGetCharacter(json, i + 6) == 92 && StringGetCharacter(json, i + 7) == 'u')
                 {
                  int l1 = HexDigit(StringGetCharacter(json, i + 8));
                  int l2 = HexDigit(StringGetCharacter(json, i + 9));
                  int l3 = HexDigit(StringGetCharacter(json, i + 10));
                  int l4 = HexDigit(StringGetCharacter(json, i + 11));
                  if(l1 >= 0 && l2 >= 0 && l3 >= 0 && l4 >= 0)
                    {
                     int low = l1 * 4096 + l2 * 256 + l3 * 16 + l4;
                     if(low >= 0xDC00 && low <= 0xDFFF)
                       {
                        long cp = 0x10000 + (long)((value - 0xD800) * 1024 + (low - 0xDC00));
                        ushort w1 = (ushort)(0xD800 + (cp >> 10));
                        ushort w2 = (ushort)(0xDC00 + (cp & 0x3FF));
                        out += ShortToString(w1) + ShortToString(w2);
                        i += 12;
                        continue;
                       }
                    }
                 }
               out += ShortToString((ushort)value);
               i += 6;
               continue;
              }
           }
        }
      //--- Append the plain character
      out += ShortToString(code);
      i++;
     }
   //--- Return what was found
   return out;
  }

//+------------------------------------------------------------------+
//| Read the text of a numeric JSON field (very small parser)        |
//+------------------------------------------------------------------+
string JsonNumberText(const string json, const string field)
  {
   //--- Locate the field name
   string needle = "\"" + field + "\"";
   int pos = StringFind(json, needle);
   if(pos < 0) return "";
   //--- Skip the name, the colon and any spaces
   int i = pos + StringLen(needle);
   while(i < StringLen(json) && (StringGetCharacter(json, i) == ':' || StringGetCharacter(json, i) == ' ')) i++;
   //--- Collect the number characters
   string out = "";
   while(i < StringLen(json))
     {
      ushort code = StringGetCharacter(json, i);
      //--- Stop at anything that is not part of a number
      if(!((code >= '0' && code <= '9') || code == '-' || code == '+' || code == '.' ||
           code == 'e' || code == 'E')) break;
      out += ShortToString(code);
      i++;
     }
   //--- Return what was found
   return out;
  }

//+------------------------------------------------------------------+
//| Lower-case copy of a string                                      |
//+------------------------------------------------------------------+
string Lower(const string text)
  {
   string out = text;
   StringToLower(out);
   return out;
  }

//+------------------------------------------------------------------+
//| Map the textual order type onto: 0 none, 1 market, 2 limit, 3 stop|
//+------------------------------------------------------------------+
int OrderKind(const string orderType)
  {
   //--- Match against the raw text and its lower-case form, so both
   //--- "MARKET" and "market" are recognised
   string s = orderType + Lower(orderType);
   if(StringLen(s) == 0) return 0;
   //--- Nothing to do
   if(StringFind(s, "不下单") >= 0 || StringFind(s, "none") >= 0 || StringFind(s, "wait") >= 0) return 0;
   //--- Market
   if(StringFind(s, "市价") >= 0 || StringFind(s, "market") >= 0) return 1;
   //--- Limit
   if(StringFind(s, "限价") >= 0 || StringFind(s, "limit") >= 0) return 2;
   //--- Stop entry (突破单 / 止损单 / breakout / stop)
   if(StringFind(s, "突破") >= 0 || StringFind(s, "止损") >= 0 ||
      StringFind(s, "stop") >= 0 || StringFind(s, "break") >= 0) return 3;
   //--- Unknown text is treated as "do nothing"
   return 0;
  }

//+------------------------------------------------------------------+
//| Map the textual direction onto: 1 long, -1 short, 0 unknown      |
//+------------------------------------------------------------------+
int DirectionOf(const string direction)
  {
   //--- Same trick as OrderKind: raw text plus its lower-case form
   string s = direction + Lower(direction);
   if(StringLen(s) == 0) return 0;
   if(StringFind(s, "多") >= 0 || StringFind(s, "buy") >= 0 || StringFind(s, "long") >= 0 ||
      StringFind(s, "bull") >= 0) return 1;
   if(StringFind(s, "空") >= 0 || StringFind(s, "sell") >= 0 || StringFind(s, "short") >= 0 ||
      StringFind(s, "bear") >= 0) return -1;
   return 0;
  }
//+------------------------------------------------------------------+
//| Read a whole file from the common folder as UTF-8 text           |
//+------------------------------------------------------------------+
bool ReadTextFile(const string relPath, string &text)
  {
   //--- Start empty
   text = "";
   //--- Open for reading, sharing with a writer that may still hold it
   int handle = FileOpen(relPath, FILE_COMMON | FILE_READ | FILE_BIN | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return false;
   //--- Pull the raw bytes
   char raw[];
   FileReadArray(handle, raw);
   FileClose(handle);
   //--- Convert from UTF-8
   int count = ArraySize(raw);
   if(count <= 0) return true;
   //--- Skip a UTF-8 byte order mark when present
   int start = 0;
   if(count >= 3 && (uchar)raw[0] == 0xEF && (uchar)raw[1] == 0xBB && (uchar)raw[2] == 0xBF) start = 3;
   //--- Convert exactly the measured number of bytes
   text = CharArrayToString(raw, start, count - start, CP_UTF8);
   return true;
  }

//+------------------------------------------------------------------+
//| Write UTF-8 text into a file of the common folder                |
//+------------------------------------------------------------------+
bool WriteTextFile(const string relPath, const string text)
  {
   //--- Convert to UTF-8 bytes first
   char bytes[];
   Utf8Bytes(text, bytes);
   //--- Open for writing and push the bytes
   int handle = FileOpen(relPath, FILE_COMMON | FILE_WRITE | FILE_BIN | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return false;
   FileWriteArray(handle, bytes);
   FileClose(handle);
   return true;
  }

//+------------------------------------------------------------------+
//| Load the list of already processed file names                    |
//+------------------------------------------------------------------+
void LoadState()
  {
   //--- Start from scratch
   ArrayResize(g_done, 0);
   string text = "";
   if(!ReadTextFile(InpStateFile, text)) return;
   //--- One file name per line
   string parts[];
   int count = StringSplit(text, '\n', parts);
   for(int i = 0; i < count; i++)
     {
      string name = parts[i];
      StringTrimLeft(name);
      StringTrimRight(name);
      StringReplace(name, "\r", "");
      if(StringLen(name) == 0) continue;
      int n = ArraySize(g_done);
      ArrayResize(g_done, n + 1);
      g_done[n] = name;
     }
  }

//+------------------------------------------------------------------+
//| Persist the list of already processed file names                 |
//+------------------------------------------------------------------+
void SaveState()
  {
   //--- Keep only the most recent entries so the file stays small
   int count = ArraySize(g_done);
   int keep  = (int)MathMax(200.0, (double)(InpMaxFilesPerScan * 100));
   int from  = 0;
   if(count > keep) from = count - keep;
   //--- Join the remaining names with newlines
   string text = "";
   for(int i = from; i < count; i++)
     {
      if(StringLen(text) > 0) text += "\n";
      text += g_done[i];
     }
   //--- Store it
   WriteTextFile(InpStateFile, text);
  }

//+------------------------------------------------------------------+
//| Has this file already been consumed?                             |
//+------------------------------------------------------------------+
bool IsDone(const string fileName)
  {
   for(int i = 0; i < ArraySize(g_done); i++)
      if(g_done[i] == fileName) return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Remember a file as consumed                                      |
//+------------------------------------------------------------------+
void MarkDone(const string fileName)
  {
   //--- Append to the in-memory list
   int n = ArraySize(g_done);
   ArrayResize(g_done, n + 1);
   g_done[n] = fileName;
   //--- And to disk
   SaveState();
  }

//+------------------------------------------------------------------+
//| Sort a string array ascending (plain insertion sort)             |
//+------------------------------------------------------------------+
void SortStrings(string &arr[])
  {
   int count = ArraySize(arr);
   for(int i = 1; i < count; i++)
     {
      string key = arr[i];
      int    j   = i - 1;
      while(j >= 0 && StringCompare(arr[j], key) > 0)
        {
         arr[j + 1] = arr[j];
         j--;
        }
      arr[j + 1] = key;
     }
  }

//+------------------------------------------------------------------+
//| Parse one signal JSON into a SignalData                          |
//+------------------------------------------------------------------+
bool ParseSignal(const string text, SignalData &sg)
  {
   //--- A symbol is the minimum requirement
   sg.symbol = JsonStringText(text, "symbol");
   if(StringLen(sg.symbol) == 0) return false;
   //--- Everything else is optional
   sg.id         = JsonStringText(text, "id");
   sg.timeframe  = JsonStringText(text, "timeframe");
   sg.orderType  = JsonStringText(text, "order_type");
   sg.direction  = JsonStringText(text, "order_direction");
   sg.reasoning  = JsonStringText(text, "reasoning");
   sg.fileName   = "";
   //--- Numbers arrive as text and may be missing
   string entry = JsonNumberText(text, "entry_price");
   string sl    = JsonNumberText(text, "stop_loss_price");
   string tp1   = JsonNumberText(text, "take_profit_price");
   string tp2   = JsonNumberText(text, "take_profit_price_2");
   string vol   = JsonNumberText(text, "volume");
   string conf  = JsonNumberText(text, "trade_confidence");
   string win   = JsonNumberText(text, "estimated_win_rate");
   string made  = JsonNumberText(text, "created_at");
   sg.entry      = (StringLen(entry) > 0) ? StringToDouble(entry) : 0.0;
   sg.sl         = (StringLen(sl)    > 0) ? StringToDouble(sl)    : 0.0;
   sg.tp1        = (StringLen(tp1)   > 0) ? StringToDouble(tp1)   : 0.0;
   sg.tp2        = (StringLen(tp2)   > 0) ? StringToDouble(tp2)   : 0.0;
   sg.volume     = (StringLen(vol)   > 0) ? StringToDouble(vol)   : 0.0;
   sg.confidence = (StringLen(conf)  > 0) ? StringToDouble(conf)  : 0.0;
   sg.winrate    = (StringLen(win)   > 0) ? StringToDouble(win)   : 0.0;
   sg.createdAt  = (StringLen(made)  > 0) ? StringToInteger(made) : 0;
   //--- Fall back to a placeholder when no id was given
   if(StringLen(sg.id) == 0) sg.id = "<no id>";
   return true;
  }
//+------------------------------------------------------------------+
//| Round a volume to what the symbol accepts                        |
//+------------------------------------------------------------------+
double NormalizeVolumeValue(const string symbol, const double volume)
  {
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   //--- Guard against a broker that reports zero contract sizes
   if(minv <= 0.0) minv = 0.01;
   if(maxv <= 0.0) maxv = 100.0;
   if(step <= 0.0) step = 0.01;
   //--- Snap to the nearest step
   double value = MathFloor(volume / step + 0.5) * step;
   if(value < minv) value = minv;
   if(value > maxv) value = maxv;
   //--- Work out how many decimals the step needs
   int digits = 0;
   double probe = step;
   while(probe < 1.0 && digits < 8)
     {
      probe *= 10.0;
      digits++;
     }
   return NormalizeDouble(value, digits);
  }

//+------------------------------------------------------------------+
//| Position sizing from the stop distance (以损订仓)                 |
//+------------------------------------------------------------------+
//| Lot = 可承受风险金额 / (止损距离 × 每跳动价值 / 每跳动价格)        |
//|                                                                  |
//| The AI never emits a lot size (hard rule in 提示词大纲), so the EA |
//| owns position sizing entirely.  Deriving the lot from the stop    |
//| keeps the money at risk constant no matter how wide or tight the  |
//| stop is: a tight stop gets a bigger lot, a wide stop a smaller    |
//| one — the loss if stopped out is always the configured amount.    |
//|                                                                  |
//| Falls back to *fallbackVolume* whenever the risk cannot be        |
//| quantified (no stop loss, or the symbol reports no tick value).   |
//+------------------------------------------------------------------+
double RiskBasedVolume(const string symbol, const double entry, const double sl,
                       const double fallbackVolume, string &note)
  {
   note = "";
   if(!InpRiskBasedLot)
      return fallbackVolume;

   //--- A stop loss is the whole basis of the calculation
   if(sl <= 0.0)
     {
      note = "以损订仓：本单无止损，无法按风险订仓，已用固定手数；";
      return fallbackVolume;
     }

   double dist = MathAbs(entry - sl);
   if(dist <= 0.0)
     {
      note = "以损订仓：止损距离为 0，已用固定手数；";
      return fallbackVolume;
     }

   //--- Money lost per 1.00 lot when price travels `dist` against us.
   //    TICK_VALUE is quoted per TICK_SIZE of price, so scale by dist/tick_size.
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0)
     {
      note = "以损订仓：品种未报告 TICK_VALUE/TICK_SIZE，已用固定手数；";
      return fallbackVolume;
     }

   double loss_per_lot = (dist / tick_size) * tick_value;
   if(loss_per_lot <= 0.0)
     {
      note = "以损订仓：每手亏损算出来是 0，已用固定手数；";
      return fallbackVolume;
     }

   //--- Risk budget: fixed amount wins, otherwise a percentage of equity
   double risk = InpRiskAmount;
   if(risk <= 0.0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0)
         equity = AccountInfoDouble(ACCOUNT_BALANCE);
      if(equity <= 0.0)
        {
         note = "以损订仓：取不到账户净值，已用固定手数；";
         return fallbackVolume;
        }
      risk = equity * InpRiskPercent / 100.0;
     }
   if(risk <= 0.0)
     {
      note = "以损订仓：风险金额为 0，已用固定手数；";
      return fallbackVolume;
     }

   double lot = risk / loss_per_lot;

   //--- Cap so a very tight stop cannot produce an absurd lot
   double cap = (InpRiskMaxLot > 0.0 ? InpRiskMaxLot
                                     : SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX));
   if(cap > 0.0 && lot > cap)
     {
      lot = cap;
      note += "已截断到手数上限；";
     }

   double volume = NormalizeVolumeValue(symbol, lot);
   note += "以损订仓：风险 " + DoubleToString(risk, 2) + " / 每手亏损 " +
           DoubleToString(loss_per_lot, 2) + " → " + DoubleToString(volume, 2) + " 手；";
   return volume;
  }

//+------------------------------------------------------------------+
//| Candidate filling modes for a symbol, best first                 |
//+------------------------------------------------------------------+
int BuildFillingCandidates(const string symbol, int &fills[])
  {
   //--- The terminal publishes a bit mask of supported modes
   long mode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   int  n    = 0;
   if((mode & 1) != 0) fills[n++] = (int)ORDER_FILLING_FOK;
   if((mode & 2) != 0) fills[n++] = (int)ORDER_FILLING_IOC;
   //--- RETURN is accepted by every symbol and is the last resort
   fills[n++] = (int)ORDER_FILLING_RETURN;
   return n;
  }

//+------------------------------------------------------------------+
//| Send one market or pending order                                 |
//+------------------------------------------------------------------+
bool SendOrder(const string symbol, const int kind, const int dir,
               const double volume, const double price,
               const double sl, const double tp,
               int &retcodeOut, ulong &orderOut, ulong &dealOut,
               double &priceOut, double &volumeOut)
  {
   //--- Clear the outputs
   retcodeOut = 0;
   orderOut   = 0;
   dealOut    = 0;
   priceOut   = 0.0;
   volumeOut  = 0.0;
   //--- Build the request
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   if(kind == 1)
     {
      request.action = TRADE_ACTION_DEAL;
      request.type   = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
     }
   else
    if(kind == 2)
      {
       request.action = TRADE_ACTION_PENDING;
       request.type   = (dir > 0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
      }
    else
      {
       request.action = TRADE_ACTION_PENDING;
       request.type   = (dir > 0 ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
      }
   request.symbol    = symbol;
   request.volume    = volume;
   request.price     = price;
   request.sl        = sl;
   request.tp        = tp;
   request.deviation = InpDeviation;
   request.magic     = InpMagic;
   request.comment   = InpComment;
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = ORDER_FILLING_RETURN;
   //--- Try the supported filling modes until one is accepted
   int fills[3];
   int count = BuildFillingCandidates(symbol, fills);
   for(int i = 0; i < count; i++)
     {
      request.type_filling = (ENUM_ORDER_TYPE_FILLING)fills[i];
      ResetLastError();
      bool sent = OrderSend(request, result);
      retcodeOut = (int)result.retcode;
      orderOut   = result.order;
      dealOut    = result.deal;
      priceOut   = result.price;
      volumeOut  = result.volume;
      //--- 10008 placed, 10009 done, 10010 partially done
      if(sent && (retcodeOut == 10008 || retcodeOut == 10009 || retcodeOut == 10010))
         return true;
      //--- 10030 = unsupported filling mode: try the next one
      if(retcodeOut == 10030) continue;
      return false;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Human readable text for the usual trade return codes             |
//+------------------------------------------------------------------+
string RetcodeText(const int code)
  {
   switch(code)
     {
      case 0:      return "未发送";
      case 10004:  return "10004 重新报价";
      case 10006:  return "10006 请求被拒绝";
      case 10007:  return "10007 请求被交易商取消";
      case 10008:  return "10008 订单已挂出";
      case 10009:  return "10009 请求已完成（成交）";
      case 10010:  return "10010 仅部分成交";
      case 10011:  return "10011 请求处理出错";
      case 10012:  return "10012 请求超时";
      case 10013:  return "10013 请求无效（结构错误）";
      case 10014:  return "10014 手数无效（检查 volume_min/step/max）";
      case 10015:  return "10015 价格无效（检查报价与 digits）";
      case 10016:  return "10016 止损/止盈无效（离市价太近？）";
      case 10017:  return "10017 该账户禁止交易";
      case 10018:  return "10018 市场关闭";
      case 10019:  return "10019 保证金不足";
      case 10020:  return "10020 价格已变动（加大偏差重试）";
      case 10021:  return "10021 价格偏离市场（挂单方向反了？）";
      case 10024:  return "10024 请求过于频繁";
      case 10027:  return "10027 自动交易被禁用：请点开终端工具栏的 Algo Trading";
      case 10028:  return "10028 订单/持仓被锁定，稍后再试";
      case 10029:  return "10029 品种处于冻结区间";
      case 10030:  return "10030 不支持的订单填充模式";
      case 10031:  return "10031 与交易服务器无连接";
      case 10032:  return "10032 只允许真实账户交易";
      case 10033:  return "10033 挂单数量已达上限";
      case 10034:  return "10034 该品种总持仓量已达上限";
      case 10038:  return "10038 平仓手数无效";
      case 10040:  return "10040 持仓数量已达上限";
      case 10042:  return "10042 该品种只允许做多";
      case 10043:  return "10043 该品种只允许做空";
      case 10044:  return "10044 该品种只允许平仓";
     }
   //--- Anything else
   return IntegerToString(code) + " 未知返回码，见 MQL5 文档 ENUM_TRADE_RETCODE";
  }

//+------------------------------------------------------------------+
//| Check (and optionally widen) the stops against the symbol limits  |
//+------------------------------------------------------------------+
string CheckStops(const string symbol, const double price, double &sl, double &tp)
  {
   //--- Nothing to check when the symbol has no limits
   int level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(level <= 0) return "";
   //--- Work in points
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) return "";
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double minDist = level * point;
   string msg = "";
   //--- Stop loss
   if(sl > 0.0)
     {
      double dist = MathAbs(price - sl);
      if(dist < minDist)
        {
         if(InpFixStopsLevel)
           {
            //--- Push the stop outwards so the server accepts it
            sl = (sl < price) ? NormalizeDouble(price - minDist - point, digits)
                              : NormalizeDouble(price + minDist + point, digits);
            msg += "SL 已自动放宽至 " + DoubleToString(sl, digits) + "；";
           }
         else
            msg += "SL 仅 " + DoubleToString(dist / point, 0) + " point < 最小 " +
                   IntegerToString(level) + " point；";
        }
     }
   //--- Take profit
   if(tp > 0.0)
     {
      double dist = MathAbs(tp - price);
      if(dist < minDist)
        {
         if(InpFixStopsLevel)
           {
            tp = (tp > price) ? NormalizeDouble(price + minDist + point, digits)
                              : NormalizeDouble(price - minDist - point, digits);
            msg += "TP 已自动放宽至 " + DoubleToString(tp, digits) + "；";
           }
         else
            msg += "TP 仅 " + DoubleToString(dist / point, 0) + " point < 最小 " +
                   IntegerToString(level) + " point；";
        }
     }
   return msg;
  }

//+------------------------------------------------------------------+
//| Turn the last signal into an order (or explain why not)          |
//+------------------------------------------------------------------+
void ExecuteSignal(const SignalData &sg, const bool manual = false)
  {
   //--- Reset the cached outcome
   g_exec.attempted = true;
   g_exec.at        = TimeLocal();
   g_exec.retcode   = 0;
   g_exec.order     = 0;
   g_exec.deal      = 0;
   g_exec.price     = 0.0;
   g_exec.volume    = 0.0;
   g_exec.note      = "";
   g_exec.ok        = false;
   //--- Dry run by default: never trade unless the user opted in.
   //    A one-click button press IS the explicit opt-in, so manual=true
   //    bypasses the InpAutoTrade gate.
   if(!InpAutoTrade && !manual)
     {
      g_exec.note = "自动下单已关闭（InpAutoTrade = false）—— 只显示信号，不下单";
      return;
     }
   //--- Signals that explicitly say "do nothing"
   int kind = OrderKind(sg.orderType);
   if(kind == 0)
     {
      g_exec.note = "该信号 order_type = " + sg.orderType + "（不下单），已忽略";
      return;
     }
   //--- Direction must be known
   int dir = DirectionOf(sg.direction);
   if(dir == 0)
     {
      g_exec.note = "无法识别 order_direction = " + sg.direction;
      return;
     }
   //--- The terminal and this EA must both be allowed to trade
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_exec.note = "终端未启用算法交易：请点开工具栏 Algo Trading 按钮 / 工具>选项>智能交易系统";
      return;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_exec.note = "本 EA 不允许交易：检查终端的自动交易设置";
      return;
     }
   //--- The symbol has to be tradeable
   string symbol = sg.symbol;
   SymbolSelect(symbol, true);
   if(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
     {
      g_exec.note = symbol + " 当前禁止交易";
      return;
     }
   //--- A fresh quote is needed for market orders and sanity checks
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
     {
      g_exec.note = "取不到 " + symbol + " 的报价（品种是否在市场报价表中？）";
      return;
     }
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;
   //--- Market orders use the live quote, pending orders the signal price
   double price;
   if(kind == 1) price = (dir > 0 ? tick.ask : tick.bid);
   else          price = sg.entry;
   if(kind != 1 && price <= 0.0)
     {
      g_exec.note = "挂单缺少 entry_price";
      return;
     }
   price = NormalizeDouble(price, digits);
   //--- Pending orders must rest on the correct side of the market. If they
   //    don't, the trade server either rejects them or fills them instantly as
   //    a MARKET deal — which is the surprising "市价单" the user never asked for.
   //    Warn, then BLOCK (do not send).  Mirrors the guard in PlaceQuickOrder.
   if(kind == 2 && dir > 0 && price >= tick.ask)
      g_exec.note += "买入限价 " + DoubleToString(price, digits) + " 不低于卖价 " +
                     DoubleToString(tick.ask, digits) + "（会立刻成交或被拒）；";
   if(kind == 2 && dir < 0 && price <= tick.bid)
      g_exec.note += "卖出限价 " + DoubleToString(price, digits) + " 不高于买价 " +
                     DoubleToString(tick.bid, digits) + "（会立刻成交或被拒）；";
   if(kind == 3 && dir > 0 && price <= tick.ask)
      g_exec.note += "买入止损 " + DoubleToString(price, digits) + " 不高于卖价（突破单方向可能反了）；";
   if(kind == 3 && dir < 0 && price >= tick.bid)
      g_exec.note += "卖出止损 " + DoubleToString(price, digits) + " 不低于买价（突破单方向可能反了）；";
   //--- Block wrong-side pending orders instead of letting them market-fill.
   if(kind != 1)
     {
      double ref = (dir > 0 ? tick.ask : tick.bid);
      bool   wrongSide = (kind == 2)
                         ? (dir > 0 ? price >= ref : price <= ref)   // limit
                         : (dir > 0 ? price <= ref : price >= ref);  // stop
      if(wrongSide)
        {
         g_exec.note = "挂单价已在市价另一侧，未下" +
            (kind == 2 ? "限价" : "突破") + "单（也不转为市价单）：计算价 " +
            DoubleToString(price, digits) + "，当前价 " + DoubleToString(ref, digits) +
            "。信号发出后价格已越过挂单位，回撤/突破接单失效；如需市价入场请让模型改发「市价单」信号。";
         return;
        }
     }
   //--- Stops
   double sl = (sg.sl  > 0.0) ? NormalizeDouble(sg.sl,  digits) : 0.0;
   double tp = (sg.tp1 > 0.0) ? NormalizeDouble(sg.tp1, digits) : 0.0;
   if(InpCheckStopsLevel)
      g_exec.note += CheckStops(symbol, price, sl, tp);
   //--- Volume
   double volume = (InpUseSignalVolume && sg.volume > 0.0) ? sg.volume : InpLot;
   //--- 以损订仓：先按总风险算出总手数，再拆分，保证两笔合计风险仍是设定值
   string risk_note = "";
   volume = RiskBasedVolume(symbol, price, sl, volume, risk_note);
   if(risk_note != "")
      g_exec.note += risk_note;
   if(InpSplitTP2 && sg.tp2 > 0.0)
      volume = volume / 2.0;
   volume = NormalizeVolumeValue(symbol, volume);
   //--- Send the first order
   int    retcode   = 0;
   ulong  order     = 0;
   ulong  deal      = 0;
   double donePrice = 0.0;
   double doneVol   = 0.0;
   bool ok = SendOrder(symbol, kind, dir, volume, price, sl, tp,
                       retcode, order, deal, donePrice, doneVol);
   g_exec.retcode = retcode;
   g_exec.order   = order;
   g_exec.deal    = deal;
   g_exec.price   = donePrice;
   g_exec.volume  = doneVol;
   g_exec.ok      = ok;
   //--- Optionally send a second order that targets TP2
   if(ok && InpSplitTP2 && sg.tp2 > 0.0)
     {
      double tp2 = NormalizeDouble(sg.tp2, digits);
      if(InpCheckStopsLevel)
        {
         double dummySL = 0.0;
         g_exec.note += CheckStops(symbol, price, dummySL, tp2);
        }
      int    rc2 = 0;
      ulong  or2 = 0;
      ulong  dl2 = 0;
      double pr2 = 0.0;
      double vo2 = 0.0;
      SendOrder(symbol, kind, dir, volume, price, sl, tp2, rc2, or2, dl2, pr2, vo2);
      g_exec.note += " TP2 第二笔 retcode " + IntegerToString(rc2) + "；";
     }
   //--- Explain the outcome
   g_exec.note += RetcodeText(retcode);
  }
//+------------------------------------------------------------------+
//| One-click order: market / limit / stop, taken from the panel      |
//+------------------------------------------------------------------+
void PlaceQuickOrder(const int dir)
  {
   //--- The buttons exist to execute the pending signal by hand: when the last
   //    signal matches this button's direction and the chart symbol, send THAT
   //    order — its 限价/突破 type, its entry price, its SL/TP — instead of a
   //    fixed-distance quick one.  Otherwise a 限价单 signal silently became a
   //    market order the moment the user clicked the button.
   //    The click itself is the explicit opt-in, so this bypasses InpAutoTrade.
   int sigDir  = DirectionOf(g_sig.direction);
   int sigKind = OrderKind(g_sig.orderType);
   bool sigStale = (InpMaxSignalAgeSec > 0 && g_sig.createdAt > 0 &&
                    (long)TimeGMT() - g_sig.createdAt > (long)InpMaxSignalAgeSec);
   if(sigKind != 0 && sigDir == dir && !sigStale &&
      StringCompare(g_sig.symbol, _Symbol, false) == 0)
     {
      ExecuteSignal(g_sig, true);
      return;
     }
   //--- No matching signal — fall back to the fixed-distance quick order
   //--- Reset the cached outcome
   ResetExec();
   g_exec.attempted = true;
   g_exec.at        = TimeLocal();
   //--- Trading must be allowed
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_exec.note = "终端未启用算法交易：请点开工具栏 Algo Trading 按钮";
      return;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_exec.note = "本 EA 不允许交易：检查终端的自动交易设置";
      return;
     }
   //--- A fresh quote is always needed
   string symbol = _Symbol;
   SymbolSelect(symbol, true);
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
     {
      g_exec.note = "取不到 " + symbol + " 的报价";
      return;
     }
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;
   //--- Order type and price
   int    kind;
   double price;
   double distance = InpQuickDistance * point;
   if(InpQuickMode == QUICK_MARKET)
     {
      kind  = 1;
      price = (dir > 0 ? tick.ask : tick.bid);
     }
   else
    if(InpQuickMode == QUICK_LIMIT)
      {
       kind  = 2;
       price = (dir > 0 ? tick.bid - distance : tick.ask + distance);
      }
    else
      {
       kind  = 3;
       price = (dir > 0 ? tick.ask + distance : tick.bid - distance);
      }
   price = NormalizeDouble(price, digits);
   //--- Pending orders: the entry price must sit on the right side of the market
   //    AND far enough away (SYMBOL_TRADE_STOPS_LEVEL).  Otherwise the server
   //    either rejects it, or the order lands on the current price and fills on
   //    the spot — which looks exactly like the button sent a market order.
   if(kind != 1)
     {
      double ref = (dir > 0 ? tick.ask : tick.bid);
      bool   wrongSide;
      if(kind == 2)  // limit: buy below the market, sell above it
         wrongSide = (dir > 0 ? price >= ref : price <= ref);
      else           // stop: buy above the market, sell below it
         wrongSide = (dir > 0 ? price <= ref : price >= ref);
      if(wrongSide)
        {
         g_exec.note = "挂单价方向错误：计算价 " + DoubleToString(price, digits) +
                       " / 当前价 " + DoubleToString(ref, digits) +
                       " —— 挂出会立刻成交（等同市价单），已取消。请检查「挂单距市价」。";
         return;
        }
      //--- Enforce the broker minimum distance for pending orders
      int level  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      int freeze = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      int need   = (level > freeze ? level : freeze);
      if(need > 0)
        {
         double minDist = need * point;
         double dist    = MathAbs(price - ref);
         if(dist < minDist)
           {
            double fixedPrice = (price > ref)
                                ? NormalizeDouble(ref + minDist + point, digits)
                                : NormalizeDouble(ref - minDist - point, digits);
            g_exec.note += "挂单价距市价仅 " + DoubleToString(dist / point, 0) +
                           " point，低于最小 " + IntegerToString(need) +
                           " point，已自动放宽至 " + DoubleToString(fixedPrice, digits) + "；";
            price = fixedPrice;
           }
        }
     }
   //--- Stops: TP defaults to the same distance as SL, which is a clean 1:1
   double slPoints = (double)InpQuickSLPoints;
   double tpPoints = (InpQuickTPPoints > 0 ? (double)InpQuickTPPoints : slPoints);
   double sl = (dir > 0 ? price - slPoints * point : price + slPoints * point);
   double tp = (dir > 0 ? price + tpPoints * point : price - tpPoints * point);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   if(InpCheckStopsLevel)
      g_exec.note += CheckStops(symbol, price, sl, tp);
   //--- Volume
   double volume = (InpQuickLot > 0.0 ? InpQuickLot : InpLot);
   //--- 以损订仓：一键单也有止损，同样按风险反推手数
   string risk_note = "";
   volume = RiskBasedVolume(symbol, price, sl, volume, risk_note);
   if(risk_note != "")
      g_exec.note += risk_note;
   volume = NormalizeVolumeValue(symbol, volume);
   //--- Send it
   int    retcode   = 0;
   ulong  order     = 0;
   ulong  deal      = 0;
   double donePrice = 0.0;
   double doneVol   = 0.0;
   bool ok = SendOrder(symbol, kind, dir, volume, price, sl, tp,
                       retcode, order, deal, donePrice, doneVol);
   g_exec.retcode = retcode;
   g_exec.order   = order;
   g_exec.deal    = deal;
   g_exec.price   = donePrice;
   g_exec.volume  = doneVol;
   g_exec.ok      = ok;
   //--- Explain the outcome
   string modeText = (InpQuickMode == QUICK_MARKET ? "市价" :
                      (InpQuickMode == QUICK_LIMIT ? "限价挂单" : "突破挂单"));
   g_exec.note += "一键" + (dir > 0 ? "做多" : "做空") + "（" + modeText + "）" +
                  (kind == 1 ? "" : " @ " + DoubleToString(price, digits)) + "：" +
                  RetcodeText(retcode);
  }

//+------------------------------------------------------------------+
//| Close every open position (optionally only the current symbol)    |
//+------------------------------------------------------------------+
void CloseAllNow()
  {
   //--- Reset the cached outcome
   ResetExec();
   g_exec.attempted = true;
   g_exec.at        = TimeLocal();
   //--- Trading must be allowed
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      g_exec.note = "终端未启用算法交易：请点开工具栏 Algo Trading 按钮";
      return;
     }
   int closed   = 0;
   int failed   = 0;
   int lastCode = 0;
   //--- Walk backwards because closing removes entries from the list
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      //--- Optionally leave other symbols alone
      if(InpQuickOnlyCurrentSymbol && symbol != _Symbol) continue;
      long   ptype = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      if(volume <= 0.0) continue;
      //--- Build the closing request (opposite side, same volume)
      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);
      request.action    = TRADE_ACTION_DEAL;
      request.position  = ticket;
      request.symbol    = symbol;
      request.volume    = volume;
      request.deviation = InpDeviation;
      request.magic     = InpMagic;
      request.comment   = "PA quick close";
      if(ptype == POSITION_TYPE_BUY)
        {
         request.type  = ORDER_TYPE_SELL;
         request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
        }
      else
        {
         request.type  = ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
        }
      request.type_time    = ORDER_TIME_GTC;
      request.type_filling = ORDER_FILLING_RETURN;
      //--- Try the supported filling modes until one is accepted
      int fills[3];
      int count = BuildFillingCandidates(symbol, fills);
      for(int f = 0; f < count; f++)
        {
         request.type_filling = (ENUM_ORDER_TYPE_FILLING)fills[f];
         ResetLastError();
         bool sent = OrderSend(request, result);
         lastCode = (int)result.retcode;
         //--- 10008 placed, 10009 done, 10010 partially done
         if(sent && (lastCode == 10008 || lastCode == 10009 || lastCode == 10010))
           {
            closed++;
            break;
           }
         //--- 10030 = unsupported filling mode: try the next one
         if(lastCode == 10030) continue;
         failed++;
         break;
        }
     }
   //--- Report
   g_exec.ok   = (failed == 0 && closed > 0);
   g_exec.note = "全部平仓：成功 " + IntegerToString(closed) +
                 " 笔，失败 " + IntegerToString(failed) + " 笔";
   if(failed > 0)
      g_exec.note += "（最后 " + RetcodeText(lastCode) + "）";
   if(closed == 0 && failed == 0)
      g_exec.note = "当前没有持仓可平";
  }

//+------------------------------------------------------------------+
//| Move only the stop loss of an open position (keep its TP)          |
//+------------------------------------------------------------------+
bool ModifyPositionSL(const ulong ticket, const string symbol,
                      const double newSL, const double keepTP)
  {
   //--- Build a SL/TP modification request
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = symbol;
   request.sl       = newSL;
   request.tp       = keepTP;   // 传当前 TP，避免误清空止盈
   request.deviation= InpDeviation;
   //--- Send and treat the usual "accepted" codes as success
   ResetLastError();
   bool sent = OrderSend(request, result);
   return (sent && (result.retcode == 10008 || result.retcode == 10009 ||
                    result.retcode == 10010));
  }

//+------------------------------------------------------------------+
//| Real-time profit protection: breakeven + profit lock               |
//+------------------------------------------------------------------+
void GuardPositions()
  {
   //--- Feature & trading-permission gates
   if(!InpProfitGuard) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return;
   //--- Throttle: at most one modification sweep per second
   datetime now = TimeCurrent();
   if(now - g_lastGuard < 1) return;
   double bePct  = InpBEStepPct / 100.0;
   double lockAt = InpLockTriggerPct / 100.0;
   if(bePct <= 0.0 && lockAt <= 0.0) return;
   double lockFrac = InpLockProfitPct / 100.0;
   //--- Walk every open position (backwards: closing/modifying is safe here)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      //--- Only manage positions this EA owns
      if(InpGuardOnlyMyMagic &&
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(InpGuardOnlyCurrentSymbol && symbol != _Symbol) continue;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp1   = PositionGetDouble(POSITION_TP);
      long   ptype = PositionGetInteger(POSITION_TYPE);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(point <= 0.0) point = 0.00001;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      //--- Mark-to-market price on the closeable side
      double mark = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                                                 : SymbolInfoDouble(symbol, SYMBOL_ASK);
      double profDist = (ptype == POSITION_TYPE_BUY) ? (mark - entry) : (entry - mark);
      if(profDist <= 0.0) continue;   // 未盈利，不动
      //--- Reference "target": TP1 if set, else a 1:1 risk distance
      double target;
      if(tp1 > 0.0)
         target = (ptype == POSITION_TYPE_BUY) ? (tp1 - entry) : (entry - tp1);
      else if(curSL > 0.0)
         target = (ptype == POSITION_TYPE_BUY) ? (entry - curSL) : (curSL - entry);
      else
         continue;                    // 无参考目标，跳过
      if(target <= 0.0) continue;
      double profitPct = profDist / target;
      //--- Decide the desired stop loss
      double desiredSL = 0.0;
      bool   doGuard   = false;
      if(lockAt > 0.0 && profitPct >= lockAt)
        {
         // 锁利：止损位 = 入场 ± lockFrac × 当前盈利（随盈利上移，自动 trailing）
         double lockDist = lockFrac * profDist;
         desiredSL = (ptype == POSITION_TYPE_BUY) ? (entry + lockDist)
                                                  : (entry - lockDist);
         doGuard = true;
        }
      else if(bePct > 0.0 && profitPct >= bePct)
        {
         desiredSL = entry;           // 保本
         doGuard = true;
        }
      if(!doGuard) continue;
      desiredSL = NormalizeDouble(desiredSL, digits);
      //--- Never loosen the stop: new SL must improve protection
      bool better = (ptype == POSITION_TYPE_BUY) ? (desiredSL > curSL + point * 0.5)
                                                : (desiredSL < curSL - point * 0.5);
      if(!better) continue;
      //--- Respect the broker's minimum stop distance
      if(InpGuardRespectStopsLevel)
        {
         int level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
         if(level > 0)
           {
            double minDist = level * point;
            double distToPrice = (ptype == POSITION_TYPE_BUY) ? (mark - desiredSL)
                                                             : (desiredSL - mark);
            if(distToPrice < minDist)
              {
               double clamped = (ptype == POSITION_TYPE_BUY)
                  ? NormalizeDouble(mark - minDist - point, digits)
                  : NormalizeDouble(mark + minDist + point, digits);
               bool cBetter = (ptype == POSITION_TYPE_BUY) ? (clamped > curSL + point * 0.5)
                                                          : (clamped < curSL - point * 0.5);
               if(!cBetter) continue;  // 放宽后会变糟，跳过本次
               desiredSL = clamped;
              }
           }
        }
      //--- Skip if the change is below one point (no real movement)
      double diff = (ptype == POSITION_TYPE_BUY) ? (desiredSL - curSL)
                                                : (curSL - desiredSL);
      if(diff < point) continue;
      //--- Apply the modification (keep the current TP untouched)
      double curTP = PositionGetDouble(POSITION_TP);
      if(ModifyPositionSL(ticket, symbol, desiredSL, curTP))
        {
         string stage = (lockAt > 0.0 && profitPct >= lockAt) ? "锁利" : "保本";
         Print("PA_Agent 盈利保护[" + symbol + " " +
               (ptype == POSITION_TYPE_BUY ? "BUY" : "SELL") + "] " + stage +
               ": 盈利 " + DoubleToString(profitPct * 100.0, 1) + "% → SL 移至 " +
               DoubleToString(desiredSL, digits) + "（原 " +
               DoubleToString(curSL, digits) + "）");
        }
     }
   g_lastGuard = now;
  }

//+------------------------------------------------------------------+
//| Copy one signal field by field (MQL5 struct assignment is limited)|
//+------------------------------------------------------------------+
void CopySignal(const SignalData &src, SignalData &dst)
  {
   dst.fileName   = src.fileName;
   dst.id         = src.id;
   dst.symbol     = src.symbol;
   dst.timeframe  = src.timeframe;
   dst.orderType  = src.orderType;
   dst.direction  = src.direction;
   dst.entry      = src.entry;
   dst.sl         = src.sl;
   dst.tp1        = src.tp1;
   dst.tp2        = src.tp2;
   dst.volume     = src.volume;
   dst.confidence = src.confidence;
   dst.winrate    = src.winrate;
   dst.createdAt  = src.createdAt;
   dst.reasoning  = src.reasoning;
  }

//+------------------------------------------------------------------+
//| Reset the cached execution outcome                               |
//+------------------------------------------------------------------+
void ResetExec()
  {
   g_exec.attempted = false;
   g_exec.at        = 0;
   g_exec.retcode   = 0;
   g_exec.order     = 0;
   g_exec.deal      = 0;
   g_exec.price     = 0.0;
   g_exec.volume    = 0.0;
   g_exec.note      = "";
   g_exec.ok        = false;
  }

//+------------------------------------------------------------------+
//| Make sure the signal folder exists                               |
//+------------------------------------------------------------------+
bool EnsureSignalFolder()
  {
   //--- Creating an existing folder is harmless
   return FolderCreate(InpSignalFolder, FILE_COMMON);
  }

//+------------------------------------------------------------------+
//| Poll the folder and consume every new signal file                |
//+------------------------------------------------------------------+
void ScanOnce()
  {
   //--- Bookkeeping
   g_lastScan = TimeLocal();
   g_scans++;
   g_pending  = 0;
   g_dirNote  = "";
   //--- List the JSON files of the signal folder
   string folder = InpSignalFolder;
   string names[];
   string found  = "";
   long handle = FileFindFirst(folder + "\\*.json", found, FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      g_dirNote = "目录不存在或没有 *.json：" + SignalFolderPath();
      return;
     }
   do
     {
      if(StringLen(found) > 0)
        {
         int k = ArraySize(names);
         ArrayResize(names, k + 1);
         names[k] = found;
        }
     }
   while(FileFindNext(handle, found));
   FileFindClose(handle);
   //--- Oldest first, so signals are consumed in chronological order
   SortStrings(names);
   int handled      = 0;
   int otherSymbol  = 0;
   int unreadable   = 0;
   //--- Walk every file
   for(int i = 0; i < ArraySize(names); i++)
     {
      string name = names[i];
      //--- Already consumed on a previous scan or a previous run
      if(IsDone(name)) continue;
      g_pending++;
      //--- Do not flood the terminal when a backlog built up
      if(handled >= InpMaxFilesPerScan) continue;
      //--- Read the file; it may still be written to, then we retry next scan
      string text = "";
      if(!ReadTextFile(folder + "\\" + name, text))
        {
         unreadable++;
         continue;
        }
      //--- Parse it
      SignalData sg;
      sg.id = ""; sg.symbol = ""; sg.timeframe = ""; sg.orderType = ""; sg.direction = "";
      sg.entry = 0.0; sg.sl = 0.0; sg.tp1 = 0.0; sg.tp2 = 0.0;
      sg.volume = 0.0; sg.confidence = 0.0; sg.winrate = 0.0;
      sg.createdAt = 0; sg.reasoning = "";
      if(!ParseSignal(text, sg))
        {
         //--- A file without a symbol is useless, do not retry forever
         MarkDone(name);
         if(InpDeleteAfterProcess) FileDelete(folder + "\\" + name, FILE_COMMON);
         handled++;
         continue;
        }
      //--- Signals for another chart are left alone
      if(InpOnlyCurrentSymbol && sg.symbol != _Symbol)
        {
         otherSymbol++;
         continue;
        }
      //--- Publish it to the panel
      sg.fileName = name;
      CopySignal(sg, g_sig);
      g_hasSig = true;
      g_raw    = text;
      //--- Reject stale signals
      if(InpMaxSignalAgeSec > 0 && sg.createdAt > 0)
        {
         long age = (long)TimeGMT() - sg.createdAt;
         if(age > (long)InpMaxSignalAgeSec)
           {
            ResetExec();
            g_exec.attempted = true;
            g_exec.at        = TimeLocal();
            g_exec.note      = "信号已过期（年龄 " + IntegerToString((int)age) + " 秒 > 限制 " +
                               IntegerToString(InpMaxSignalAgeSec) + " 秒），未下单";
            MarkDone(name);
            if(InpDeleteAfterProcess) FileDelete(folder + "\\" + name, FILE_COMMON);
            handled++;
            continue;
           }
        }
      //--- Trade it (or only report it, depending on InpAutoTrade)
      ExecuteSignal(sg);
      //--- Remember and optionally remove the file
      MarkDone(name);
      if(InpDeleteAfterProcess) FileDelete(folder + "\\" + name, FILE_COMMON);
      handled++;
     }
   //--- Summarise what happened
   if(otherSymbol > 0)
      g_dirNote += "忽略 " + IntegerToString(otherSymbol) + " 个非当前品种的文件（InpOnlyCurrentSymbol=true）；";
   if(unreadable > 0)
      g_dirNote += IntegerToString(unreadable) + " 个文件读取失败（可能正在写入，下轮重试）；";
   if(g_pending > InpMaxFilesPerScan)
      g_dirNote += "积压 " + IntegerToString(g_pending) + " 个文件，每次最多处理 " +
                   IntegerToString(InpMaxFilesPerScan) + " 个；";
  }

//+------------------------------------------------------------------+
//| Write a sample signal so the whole chain can be tested           |
//+------------------------------------------------------------------+
void WriteTestSignal()
  {
   //--- Make sure the target folder exists
   EnsureSignalFolder();
   //--- A fresh quote to price the sample
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      ResetExec();
      g_exec.attempted = true;
      g_exec.at        = TimeLocal();
      g_exec.note      = "写测试信号失败：取不到 " + _Symbol + " 的报价";
      return;
     }
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0) point = 0.00001;
   double entry = tick.ask;
   double sl    = NormalizeDouble(entry - 20.0 * point, digits);
   double tp1   = NormalizeDouble(entry + 40.0 * point, digits);
   double tp2   = NormalizeDouble(entry + 80.0 * point, digits);
   //--- The file name carries a timestamp so the lexical order is chronological
   MqlDateTime now;
   TimeToStruct(TimeLocal(), now);
   string stamp = StringFormat("%04d%02d%02d_%02d%02d%02d",
                               now.year, now.mon, now.day, now.hour, now.min, now.sec);
   string fileName = "signal_" + stamp + "_" + _Symbol + ".json";
   string id       = "test_" + stamp;
   //--- Assemble the JSON exactly as PA Agent is expected to do
   string body = "{";
   body += "\"id\":\"" + JsonEscape(id) + "\",";
   body += "\"symbol\":\"" + JsonEscape(_Symbol) + "\",";
   body += "\"timeframe\":\"" + JsonEscape(TimeframeText()) + "\",";
   body += "\"order_type\":\"市价单\",";
   body += "\"order_direction\":\"做多\",";
   body += "\"entry_price\":" + DoubleToString(entry, digits) + ",";
   body += "\"stop_loss_price\":" + DoubleToString(sl, digits) + ",";
   body += "\"take_profit_price\":" + DoubleToString(tp1, digits) + ",";
   body += "\"take_profit_price_2\":" + DoubleToString(tp2, digits) + ",";
   body += "\"volume\":" + DoubleToString(InpLot, 2) + ",";
   body += "\"trade_confidence\":0.70,";
   body += "\"estimated_win_rate\":60,";
   body += "\"created_at\":" + IntegerToString((long)TimeGMT()) + ",";
   body += "\"reasoning\":\"" + JsonEscape("MQ5 面板生成的测试信号（做多示例）") + "\"";
   body += "}";
   //--- Store it next to the real signals
   bool written = WriteTextFile(InpSignalFolder + "\\" + fileName, body);
   ResetExec();
   g_exec.attempted = true;
   g_exec.at        = TimeLocal();
   g_exec.ok        = written;
   if(written)
      g_exec.note = "已写入测试信号 " + fileName + "；下次扫描（" +
                    IntegerToString(InpPollSeconds) + " 秒内）会读取它" +
                    (InpAutoTrade ? "，⚠ 自动下单已开启，会真实下单！" : "（自动下单已关闭，只显示）");
   else
      g_exec.note = "写入失败：" + SignalFolderPath() + " —— 请确认目录存在";
  }
//+------------------------------------------------------------------+
//| Rebuild the line buffer with the whole panel content             |
//+------------------------------------------------------------------+
void BuildPanelLines()
  {
   //--- Start from scratch
   ArrayResize(g_lines, 0);
   //--- Title
   AddPanelLine("PA AGENT 信号桥   " + _Symbol + " " + TimeframeText(), InpTitleColor);
   AddPanelLine("────────────────────────────────────────────────────────────────────", InpBorderColor);
   //--- Folder and polling state
   AddWrapped("目录   : " + SignalFolderPath(), InpTextColor);
   AddPanelLine("轮询   : " + IntegerToString(InpPollSeconds) + " 秒    扫描 " +
                IntegerToString(g_scans) + " 次    上次 " + TimeToString(g_lastScan, TIME_SECONDS), InpTextColor);
   AddPanelLine("状态   : 待处理 " + IntegerToString(g_pending) +
                "    已处理 " + IntegerToString(ArraySize(g_done)), InpTextColor);
   if(StringLen(g_dirNote) > 0)
      AddWrapped("注意   : " + g_dirNote, InpWarnColor);
   //--- Latest signal
   AddPanelLine("── 最新信号 ──", InpTitleColor);
   if(!g_hasSig)
     {
      AddPanelLine("还没有读到信号。点 [写测试信号] 生成一份示例，", InpTextColor);
      AddPanelLine("或让 PA Agent 按文件头注释的契约把 JSON 写进上面的目录。", InpTextColor);
     }
   else
     {
      //--- Identity
      AddWrapped("文件   : " + g_sig.fileName, InpTextColor);
      AddWrapped("ID     : " + g_sig.id, InpTextColor);
      AddPanelLine("品种   : " + g_sig.symbol + "    周期 " + g_sig.timeframe, InpTextColor);
      //--- Order intent
      int  kind = OrderKind(g_sig.orderType);
      int  dir  = DirectionOf(g_sig.direction);
      string kindText = (kind == 1 ? "市价" : (kind == 2 ? "限价挂单" : (kind == 3 ? "突破挂单" : "不下单")));
      string dirText  = (dir > 0 ? "做多" : (dir < 0 ? "做空" : "方向未知"));
      AddPanelLine("指令   : " + g_sig.orderType + " / " + g_sig.direction +
                   "    => " + kindText + " " + dirText,
                   kind == 0 ? InpWarnColor : InpTextColor);
      //--- Prices
      int digits = (int)SymbolInfoInteger(g_sig.symbol, SYMBOL_DIGITS);
      if(digits <= 0) digits = 2;
      AddPanelLine("价格   : entry " + DoubleToString(g_sig.entry, digits) +
                   "   SL " + DoubleToString(g_sig.sl, digits) +
                   "   TP1 " + DoubleToString(g_sig.tp1, digits) +
                   "   TP2 " + DoubleToString(g_sig.tp2, digits), InpTextColor);
      //--- Size and quality
      string volText = DoubleToString((g_sig.volume > 0.0 ? g_sig.volume : InpLot), 2) +
                       (g_sig.volume > 0.0 ? "（来自信号）" : "（默认手数）");
      AddPanelLine("手数   : " + volText + "    置信度 " + DoubleToString(g_sig.confidence, 2) +
                   "    胜率 " + DoubleToString(g_sig.winrate, 0), InpTextColor);
      //--- Age
      if(g_sig.createdAt > 0)
         AddPanelLine("时间   : " + TimeToString((datetime)g_sig.createdAt, TIME_DATE | TIME_SECONDS) +
                      " UTC    年龄 " + IntegerToString((int)((long)TimeGMT() - g_sig.createdAt)) + " 秒", InpTextColor);
      else
         AddPanelLine("时间   : 信号没有 created_at，无法判断时效", InpWarnColor);
      //--- Reasoning and raw JSON
      if(StringLen(g_sig.reasoning) > 0) AddWrapped("理由   : " + g_sig.reasoning, InpTextColor);
      if(StringLen(g_raw) > 0)           AddWrapped("原始   : " + TruncateText(g_raw, InpMaxJsonChars), InpBorderColor);
     }
   //--- Execution block
   AddPanelLine("── 执行 ──", InpTitleColor);
   AddPanelLine("自动下单: " + (InpAutoTrade ? "开启    magic " + IntegerToString(InpMagic) +
                                               "    偏差 " + IntegerToString(InpDeviation)
                                            : "关闭（只看不交易）"),
                InpAutoTrade ? InpWarnColor : InpTextColor);
   if(g_exec.attempted)
     {
      AddPanelLine("retcode : " + IntegerToString(g_exec.retcode) + "    " + RetcodeText(g_exec.retcode),
                   g_exec.ok ? InpOkColor : (InpAutoTrade ? InpFailColor : InpTextColor));
      AddPanelLine("order   : " + IntegerToString((int)g_exec.order) +
                   "    deal " + IntegerToString((int)g_exec.deal) +
                   "    价 " + DoubleToString(g_exec.price, 5) +
                   "    量 " + DoubleToString(g_exec.volume, 2), InpTextColor);
      AddPanelLine("时间   : " + TimeToString(g_exec.at, TIME_DATE | TIME_SECONDS), InpTextColor);
      if(StringLen(g_exec.note) > 0) AddWrapped("说明   : " + g_exec.note, InpWarnColor);
     }
   else
      AddPanelLine("尚未处理任何信号。", InpTextColor);
   //--- Verdict
   string verdict;
   if(!g_hasSig)
      verdict = "RESULT : 等待信号文件 …";
   else
    if(!InpAutoTrade)
      verdict = "RESULT : 信号已读取，自动下单关闭";
   else
    if(g_exec.ok)
      verdict = "RESULT : 已下单成功 —— 到终端「交易」标签确认";
   else
      verdict = "RESULT : 未下单 / 被拒绝 —— 看上面 retcode";
   AddPanelLine(verdict, (g_exec.ok && InpAutoTrade) ? InpOkColor : (InpAutoTrade ? InpFailColor : InpTextColor));
   //--- Footer
   AddPanelLine("────────────────────────────────────────────────────────────────────", InpBorderColor);
   AddPanelLine("契约: symbol/order_type/order_direction/entry_price/stop_loss_price/take_profit_price", InpBorderColor);
   AddPanelLine("参数改动后需重新加载本 EA；[清空状态] 会重新读取全部历史文件", InpBorderColor);
  }

//+------------------------------------------------------------------+
//| Create or update a label object                                  |
//+------------------------------------------------------------------+
void DrawLabel(const string name, const int x, const int y, const string text, const color clr)
  {
   //--- Create the label once
   if(ObjectFind(0, name) < 0)
     {
      //--- Build a plain text label
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 2);
     }
   //--- Place, colour and fill the label
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| Create or update a button object                                 |
//+------------------------------------------------------------------+
void DrawButton(const string name, const int x, const int y, const int w, const int h, const string text)
  {
   //--- Create the button once
   if(ObjectFind(0, name) < 0)
     {
      //--- Build a clickable button
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 3);
     }
   //--- Place and style the button
   ObjectSetInteger(0, name, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'38,48,62');
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpTextColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, InpBorderColor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| Redraw the whole panel                                           |
//+------------------------------------------------------------------+
void RefreshPanel()
  {
   //--- Rebuild the logical content first
   BuildPanelLines();
   //--- Panel geometry
   int padX   = 8;
   int padY   = 6;
   int lines  = ArraySize(g_lines);
   int btnH   = 22;
   int btnGap = 6;
   int width  = (int)MathMax(240.0, (double)InpPanelWidth);
   //--- Two rows of buttons: folder tools on top, quick trading below
   int height = padY * 2 + lines * InpLineHeight + btnH * 2 + btnGap + 14;
   //--- Background rectangle
   if(ObjectFind(0, SB_BG) < 0)
     {
      //--- Create the panel frame once
      ObjectCreate(0, SB_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, SB_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, SB_BG, OBJPROP_BACK, false);
      ObjectSetInteger(0, SB_BG, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, SB_BG, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, SB_BG, OBJPROP_ZORDER, 1);
     }
   ObjectSetInteger(0, SB_BG, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, SB_BG, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, SB_BG, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, SB_BG, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, SB_BG, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, SB_BG, OBJPROP_BGCOLOR, InpBackColor);
   ObjectSetInteger(0, SB_BG, OBJPROP_COLOR, InpBorderColor);
   ObjectSetInteger(0, SB_BG, OBJPROP_WIDTH, 1);
   //--- Every text line
   for(int i = 0; i < lines; i++)
      DrawLabel(SB_LINE_PFX + IntegerToString(i), InpPanelX + padX, InpPanelY + padY + i * InpLineHeight,
                g_lines[i].text, g_lines[i].clr);
   //--- Drop labels left over from a longer previous render
   for(int i = lines; i < g_drawnLines; i++)
      ObjectDelete(0, SB_LINE_PFX + IntegerToString(i));
   g_drawnLines = lines;
   //--- Buttons: folder tools (row 1) and quick trading (row 2)
   int btnY2 = InpPanelY + height - btnH - 6;
   int btnY1 = btnY2 - btnH - btnGap;
   DrawButton(SB_BTN_SCAN,  InpPanelX + padX,          btnY1, 100, btnH, "立即扫描");
   DrawButton(SB_BTN_TEST,  InpPanelX + padX + 108,    btnY1, 120, btnH, "写测试信号");
   DrawButton(SB_BTN_CLEAR, InpPanelX + padX + 236,    btnY1, 100, btnH, "清空状态");
   DrawButton(SB_BTN_BUY,   InpPanelX + padX,          btnY2, 100, btnH, "一键做多");
   DrawButton(SB_BTN_SELL,  InpPanelX + padX + 108,    btnY2, 100, btnH, "一键做空");
   DrawButton(SB_BTN_CLOSE, InpPanelX + padX + 216,    btnY2, 120, btnH, "全部平仓");
   //--- Repaint the chart
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
