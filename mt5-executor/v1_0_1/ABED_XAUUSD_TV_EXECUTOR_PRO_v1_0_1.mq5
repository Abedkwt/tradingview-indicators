//+------------------------------------------------------------------+
//| ABED_XAUUSD_TV_EXECUTOR_PRO_v1_0_1.mq5                           |
//| TradingView JSON file executor for MT5                           |
//| Phase 1.0.1: Tester self-test + local JSON executor               |
//|                                                                  |
//| Engineering purpose:                                              |
//|  - Live/demo chart: reads ABED_TV_SIGNAL.json from Common Files    |
//|  - Strategy Tester: optional self-test mode opens one test trade   |
//|  - Validates secret, symbol, spread, duplicates, daily limits      |
//|  - Executes BUY / SELL / CLOSE_ALL / CLOSE_BUY / CLOSE_SELL        |
//|  - Logs every action to CSV                                       |
//|                                                                  |
//| IMPORTANT: This EA is an executor only. TradingView/Pine remains   |
//| the strategy brain. Strategy Tester self-test only proves MT5      |
//| execution works; it is not a profitability backtest.               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.01"
#property description "ABED XAUUSD TradingView Executor PRO v1.0.1 - local JSON + tester self-test"

#include <Trade/Trade.mqh>

CTrade trade;

//------------------------- Inputs ----------------------------------//
input string InpSecret                   = "ABED_SECRET_2026";
input string InpSignalFileName           = "ABED_TV_SIGNAL.json";
input string InpLastAlertFileName        = "ABED_TV_LAST_ALERT_ID.txt";
input string InpLogFileName              = "ABED_TV_EXECUTOR_LOG.csv";
input bool   InpUseCommonFilesFolder     = true;

input string InpAllowedSymbolText        = "XAU";       // Chart symbol must contain this text, e.g. XAU / GOLD
input bool   InpRequireAlertSymbolMatch  = false;       // False supports XAUUSDm, GOLD, etc.

input bool   InpEnableTrading            = true;
input bool   InpAllowBuy                 = true;
input bool   InpAllowSell                = true;
input bool   InpCloseOppositeBeforeOpen  = false;

input bool   InpUseFixedLot              = true;
input double InpFixedLot                 = 0.01;
input double InpRiskPercent              = 0.50;        // Used only if InpUseFixedLot=false

input int    InpMaxSpreadPoints          = 500;         // Broker points. Increase only for testing if needed.
input int    InpSlippagePoints           = 30;
input int    InpMaxOpenTrades            = 1;
input int    InpMaxTradesPerDay          = 3;
input double InpMaxDailyLossPercent      = 2.0;         // 0 = disabled

input int    InpTimerSeconds             = 2;
input long   InpMagicNumber              = 260602011;
input bool   InpUseTP2AsMainTP           = true;        // True = order TP uses TP2. False = order TP uses TP1.
input bool   InpDeleteSignalAfterProcess = false;

// Strategy Tester only. Safe default because it runs only inside MT5 Strategy Tester.
input bool   InpTesterSelfTestMode       = true;
input string InpTesterTestAction         = "BUY";       // BUY or SELL
input int    InpTesterBarsBeforeTest     = 5;
input int    InpTesterSLPoints           = 500;
input int    InpTesterTP1Points          = 700;
input int    InpTesterTP2Points          = 1200;

//------------------------- State -----------------------------------//
string   g_last_alert_id      = "";
datetime g_last_timer_run     = 0;
datetime g_last_bar_time      = 0;
int      g_tester_bar_count    = 0;
bool     g_tester_signal_sent  = false;

//------------------------- String Helpers --------------------------//
string TrimText(string s)
{
   int len = StringLen(s);
   int left = 0;
   int right = len - 1;

   while(left < len)
   {
      ushort c = StringGetCharacter(s, left);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n')
         break;
      left++;
   }

   while(right >= left)
   {
      ushort c = StringGetCharacter(s, right);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n')
         break;
      right--;
   }

   if(right < left)
      return "";

   return StringSubstr(s, left, right - left + 1);
}

string UpperText(string s)
{
   StringToUpper(s);
   return s;
}

//------------------------- File Helpers ----------------------------//
bool IsCommon()
{
   return InpUseCommonFilesFolder;
}

int ReadFlags()
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

int WriteFlags()
{
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

int CsvFlagsReadWrite()
{
   int flags = FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

int CsvFlagsWrite()
{
   int flags = FILE_WRITE | FILE_CSV | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

string ReadWholeFile(const string file_name)
{
   int handle = FileOpen(file_name, ReadFlags());
   if(handle == INVALID_HANDLE)
      return "";

   long size = FileSize(handle);
   string data = "";

   if(size > 0)
      data = FileReadString(handle, (int)size);

   FileClose(handle);
   return data;
}

bool WriteWholeFile(const string file_name, const string text)
{
   int handle = FileOpen(file_name, WriteFlags());
   if(handle == INVALID_HANDLE)
      return false;

   FileWriteString(handle, text);
   FileClose(handle);
   return true;
}

void EnsureLogHeader()
{
   int handle = FileOpen(InpLogFileName, CsvFlagsReadWrite());
   if(handle == INVALID_HANDLE)
      handle = FileOpen(InpLogFileName, CsvFlagsWrite());

   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(handle,
                "server_time",
                "level",
                "symbol",
                "action",
                "alert_id",
                "message",
                "bid",
                "ask",
                "spread_points",
                "equity",
                "balance");
   }

   FileClose(handle);
}

void WriteLog(const string level,
              const string action,
              const string alert_id,
              const string message)
{
   EnsureLogHeader();

   int handle = FileOpen(InpLogFileName, CsvFlagsReadWrite());
   if(handle == INVALID_HANDLE)
      handle = FileOpen(InpLogFileName, CsvFlagsWrite());

   if(handle == INVALID_HANDLE)
   {
      Print(level, " | ", action, " | ", alert_id, " | ", message);
      return;
   }

   FileSeek(handle, 0, SEEK_END);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread = CurrentSpreadPoints();

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             level,
             _Symbol,
             action,
             alert_id,
             message,
             DoubleToString(bid, _Digits),
             DoubleToString(ask, _Digits),
             DoubleToString(spread, 1),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));

   FileClose(handle);
   Print(level, " | ", action, " | ", alert_id, " | ", message);
}

//------------------------- JSON Helpers ----------------------------//
string JsonRawValue(const string json, const string key)
{
   string pattern = "\"" + key + "\"";
   int key_pos = StringFind(json, pattern);
   if(key_pos < 0)
      return "";

   int colon_pos = StringFind(json, ":", key_pos + StringLen(pattern));
   if(colon_pos < 0)
      return "";

   int start = colon_pos + 1;
   int total = StringLen(json);

   while(start < total)
   {
      ushort c = StringGetCharacter(json, start);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n')
         break;
      start++;
   }

   if(start >= total)
      return "";

   bool quoted = (StringGetCharacter(json, start) == '"');
   if(quoted)
   {
      int endq = StringFind(json, "\"", start + 1);
      if(endq < 0)
         return "";
      return StringSubstr(json, start + 1, endq - start - 1);
   }

   int end_comma = StringFind(json, ",", start);
   int end_brace = StringFind(json, "}", start);
   int end = total;

   if(end_comma >= 0 && end_brace >= 0)
      end = MathMin(end_comma, end_brace);
   else if(end_comma >= 0)
      end = end_comma;
   else if(end_brace >= 0)
      end = end_brace;

   return TrimText(StringSubstr(json, start, end - start));
}

string JsonString(const string json, const string key, const string default_value="")
{
   string value = TrimText(JsonRawValue(json, key));
   if(value == "")
      return default_value;
   return value;
}

double JsonDouble(const string json, const string key, const double default_value=0.0)
{
   string value = TrimText(JsonRawValue(json, key));
   if(value == "")
      return default_value;
   return StringToDouble(value);
}

//------------------------- Market / Risk Helpers -------------------//
double CurrentSpreadPoints()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(_Point <= 0.0)
      return 999999.0;
   return (ask - bid) / _Point;
}

bool SpreadOK()
{
   return (CurrentSpreadPoints() <= InpMaxSpreadPoints);
}

bool SymbolAllowedByChart()
{
   string sym = UpperText(_Symbol);
   string allowed = UpperText(InpAllowedSymbolText);
   if(allowed == "")
      return true;
   return (StringFind(sym, allowed) >= 0);
}

bool AlertSymbolMatches(const string alert_symbol)
{
   if(!InpRequireAlertSymbolMatch)
      return true;

   if(alert_symbol == "")
      return false;

   string chart_sym = UpperText(_Symbol);
   string alert_sym = UpperText(alert_symbol);

   if(chart_sym == alert_sym)
      return true;

   if(StringFind(chart_sym, alert_sym) >= 0 || StringFind(alert_sym, chart_sym) >= 0)
      return true;

   return false;
}

double NormalizeVolume(double volume)
{
   double min_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step_vol <= 0.0)
      step_vol = 0.01;

   if(volume < min_vol)
      volume = min_vol;
   if(volume > max_vol)
      volume = max_vol;

   volume = MathFloor(volume / step_vol) * step_vol;

   int digits = 2;
   if(step_vol >= 1.0)
      digits = 0;
   else if(step_vol >= 0.1)
      digits = 1;
   else if(step_vol >= 0.01)
      digits = 2;
   else if(step_vol >= 0.001)
      digits = 3;
   else
      digits = 4;

   return NormalizeDouble(volume, digits);
}

double CalculateLot(const double entry_price, const double sl_price)
{
   if(InpUseFixedLot)
      return NormalizeVolume(InpFixedLot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = equity * (InpRiskPercent / 100.0);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tick_size <= 0.0 || tick_value <= 0.0)
      return NormalizeVolume(InpFixedLot);

   double distance = MathAbs(entry_price - sl_price);
   if(distance <= 0.0)
      return NormalizeVolume(InpFixedLot);

   double loss_per_lot = (distance / tick_size) * tick_value;
   if(loss_per_lot <= 0.0)
      return NormalizeVolume(InpFixedLot);

   return NormalizeVolume(risk_money / loss_per_lot);
}

int CountOpenPositions(const int direction_filter=-1)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(direction_filter >= 0 && type != direction_filter)
         continue;

      count++;
   }

   return count;
}

bool HasSameDirectionPosition(const string action)
{
   string act = UpperText(action);
   if(act == "BUY")
      return (CountOpenPositions(POSITION_TYPE_BUY) > 0);
   if(act == "SELL")
      return (CountOpenPositions(POSITION_TYPE_SELL) > 0);
   return false;
}

void ClosePositionsByType(const int position_type, const string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(position_type >= 0 && type != position_type)
         continue;

      bool closed = trade.PositionClose(ticket);
      if(closed)
         WriteLog("INFO", "CLOSE", "", reason + " | ticket=" + IntegerToString((int)ticket));
      else
         WriteLog("ERROR", "CLOSE", "", reason + " failed | retcode=" + IntegerToString((int)trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   }
}

datetime TodayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

int TodayEntryTradesCount()
{
   datetime start = TodayStart();
   datetime now = TimeCurrent();
   if(!HistorySelect(start, now))
      return 0;

   int count = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;

      if((int)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

double TodayClosedProfit()
{
   datetime start = TodayStart();
   datetime now = TimeCurrent();
   if(!HistorySelect(start, now))
      return 0.0;

   double profit = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;

      int entry_type = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_INOUT)
      {
         profit += HistoryDealGetDouble(deal, DEAL_PROFIT);
         profit += HistoryDealGetDouble(deal, DEAL_SWAP);
         profit += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
   }
   return profit;
}

bool DailyLimitsOK(string &why_not)
{
   why_not = "";

   if(InpMaxTradesPerDay > 0 && TodayEntryTradesCount() >= InpMaxTradesPerDay)
   {
      why_not = "Max trades per day reached";
      return false;
   }

   if(InpMaxDailyLossPercent > 0.0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double max_loss_money = balance * (InpMaxDailyLossPercent / 100.0);
      double today_profit = TodayClosedProfit();

      if(today_profit <= -max_loss_money)
      {
         why_not = "Max daily loss reached";
         return false;
      }
   }

   return true;
}

bool StopsDistanceOK(const string action,
                     const double entry,
                     const double sl,
                     const double tp,
                     string &why_not)
{
   why_not = "";
   string act = UpperText(action);

   if(act == "BUY")
   {
      if(sl <= 0.0 || sl >= entry)
      {
         why_not = "Invalid BUY SL. SL must be below market.";
         return false;
      }
      if(tp > 0.0 && tp <= entry)
      {
         why_not = "Invalid BUY TP. TP must be above market.";
         return false;
      }
   }
   else if(act == "SELL")
   {
      if(sl <= 0.0 || sl <= entry)
      {
         why_not = "Invalid SELL SL. SL must be above market.";
         return false;
      }
      if(tp > 0.0 && tp >= entry)
      {
         why_not = "Invalid SELL TP. TP must be below market.";
         return false;
      }
   }

   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stops_level * _Point;

   if(min_distance > 0.0)
   {
      if(MathAbs(entry - sl) < min_distance)
      {
         why_not = "SL too close to market. Broker stop level=" + IntegerToString(stops_level) + " points.";
         return false;
      }
      if(tp > 0.0 && MathAbs(entry - tp) < min_distance)
      {
         why_not = "TP too close to market. Broker stop level=" + IntegerToString(stops_level) + " points.";
         return false;
      }
   }

   return true;
}

void LoadLastAlertId()
{
   g_last_alert_id = TrimText(ReadWholeFile(InpLastAlertFileName));
}

void SaveLastAlertId(const string alert_id)
{
   g_last_alert_id = alert_id;
   WriteWholeFile(InpLastAlertFileName, alert_id);
}

void DeleteSignalFileIfNeeded()
{
   if(!InpDeleteSignalAfterProcess)
      return;

   int common_flag = 0;
   if(IsCommon())
      common_flag = FILE_COMMON;

   FileDelete(InpSignalFileName, common_flag);
}

//------------------------- Execution -------------------------------//
bool ExecuteMarketOrder(const string action,
                        const string alert_id,
                        const double signal_sl,
                        const double signal_tp1,
                        const double signal_tp2,
                        const string reason)
{
   string act = UpperText(action);

   if(!InpEnableTrading)
   {
      WriteLog("BLOCK", act, alert_id, "Trading disabled by input");
      return false;
   }

   if(act == "BUY" && !InpAllowBuy)
   {
      WriteLog("BLOCK", act, alert_id, "BUY disabled by input");
      return false;
   }

   if(act == "SELL" && !InpAllowSell)
   {
      WriteLog("BLOCK", act, alert_id, "SELL disabled by input");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      WriteLog("BLOCK", act, alert_id, "Terminal trading not allowed. Turn Algo Trading ON.");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      WriteLog("BLOCK", act, alert_id, "EA trading permission disabled. Check Allow Algo Trading in EA settings.");
      return false;
   }

   if(!SymbolAllowedByChart())
   {
      WriteLog("BLOCK", act, alert_id, "Chart symbol blocked: " + _Symbol + ". Allowed text=" + InpAllowedSymbolText);
      return false;
   }

   if(!SpreadOK())
   {
      WriteLog("BLOCK", act, alert_id, "Spread too high: " + DoubleToString(CurrentSpreadPoints(), 1) + " > " + IntegerToString(InpMaxSpreadPoints));
      return false;
   }

   string daily_reason = "";
   if(!DailyLimitsOK(daily_reason))
   {
      WriteLog("BLOCK", act, alert_id, daily_reason);
      return false;
   }

   if(CountOpenPositions(-1) >= InpMaxOpenTrades)
   {
      WriteLog("BLOCK", act, alert_id, "Max open trades reached");
      return false;
   }

   if(HasSameDirectionPosition(act))
   {
      WriteLog("BLOCK", act, alert_id, "Duplicate same-direction position blocked");
      return false;
   }

   if(InpCloseOppositeBeforeOpen)
   {
      if(act == "BUY")
         ClosePositionsByType(POSITION_TYPE_SELL, "Close opposite before BUY");
      else if(act == "SELL")
         ClosePositionsByType(POSITION_TYPE_BUY, "Close opposite before SELL");
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (act == "BUY") ? ask : bid;

   double tp = 0.0;
   if(InpUseTP2AsMainTP && signal_tp2 > 0.0)
      tp = signal_tp2;
   else if(signal_tp1 > 0.0)
      tp = signal_tp1;
   else if(signal_tp2 > 0.0)
      tp = signal_tp2;

   double sl = signal_sl;

   string stop_reason = "";
   if(!StopsDistanceOK(act, entry, sl, tp, stop_reason))
   {
      WriteLog("BLOCK", act, alert_id, stop_reason + " entry=" + DoubleToString(entry, _Digits) + " sl=" + DoubleToString(sl, _Digits) + " tp=" + DoubleToString(tp, _Digits));
      return false;
   }

   double lot = CalculateLot(entry, sl);
   if(lot <= 0.0)
   {
      WriteLog("BLOCK", act, alert_id, "Lot calculation failed");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool sent = false;
   string comment = "ABED_TV_EXEC_v101|" + alert_id;

   if(act == "BUY")
      sent = trade.Buy(lot, _Symbol, 0.0, sl, tp, comment);
   else if(act == "SELL")
      sent = trade.Sell(lot, _Symbol, 0.0, sl, tp, comment);

   if(sent)
   {
      string msg = "ORDER SENT lot=" + DoubleToString(lot, 2) +
                   " sl=" + DoubleToString(sl, _Digits) +
                   " tp=" + DoubleToString(tp, _Digits) +
                   " spread=" + DoubleToString(CurrentSpreadPoints(), 1) +
                   " reason=" + reason;
      WriteLog("EXECUTED", act, alert_id, msg);
      return true;
   }

   string err = "Order failed retcode=" + IntegerToString((int)trade.ResultRetcode()) +
                " desc=" + trade.ResultRetcodeDescription();
   WriteLog("ERROR", act, alert_id, err);
   return false;
}

void ProcessSignal(const string json)
{
   if(json == "")
      return;

   string secret       = JsonString(json, "secret", "");
   string strategy     = JsonString(json, "strategy", "");
   string alert_symbol = JsonString(json, "symbol", "");
   string timeframe    = JsonString(json, "timeframe", "");
   string action       = UpperText(JsonString(json, "action", ""));
   string alert_id     = JsonString(json, "alert_id", "");
   string reason       = JsonString(json, "reason", "");

   double sl  = JsonDouble(json, "sl", 0.0);
   double tp1 = JsonDouble(json, "tp1", 0.0);
   double tp2 = JsonDouble(json, "tp2", 0.0);

   if(action == "")
   {
      WriteLog("BLOCK", "", alert_id, "Missing action in JSON");
      return;
   }

   if(secret != InpSecret)
   {
      WriteLog("BLOCK", action, alert_id, "Secret mismatch");
      return;
   }

   if(alert_id == "")
      alert_id = action + "_" + timeframe + "_" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);

   if(alert_id == g_last_alert_id)
      return;

   if(!AlertSymbolMatches(alert_symbol))
   {
      WriteLog("BLOCK", action, alert_id, "Alert symbol mismatch. alert=" + alert_symbol + " chart=" + _Symbol);
      SaveLastAlertId(alert_id);
      return;
   }

   if(action == "CLOSE_ALL")
   {
      ClosePositionsByType(-1, "CLOSE_ALL alert");
      SaveLastAlertId(alert_id);
      DeleteSignalFileIfNeeded();
      return;
   }

   if(action == "CLOSE_BUY")
   {
      ClosePositionsByType(POSITION_TYPE_BUY, "CLOSE_BUY alert");
      SaveLastAlertId(alert_id);
      DeleteSignalFileIfNeeded();
      return;
   }

   if(action == "CLOSE_SELL")
   {
      ClosePositionsByType(POSITION_TYPE_SELL, "CLOSE_SELL alert");
      SaveLastAlertId(alert_id);
      DeleteSignalFileIfNeeded();
      return;
   }

   if(action != "BUY" && action != "SELL")
   {
      WriteLog("BLOCK", action, alert_id, "Unsupported action. v1.0.1 supports BUY, SELL, CLOSE_ALL, CLOSE_BUY, CLOSE_SELL.");
      SaveLastAlertId(alert_id);
      return;
   }

   bool ok = ExecuteMarketOrder(action, alert_id, sl, tp1, tp2, reason + " | strategy=" + strategy);
   SaveLastAlertId(alert_id);

   if(ok)
      DeleteSignalFileIfNeeded();
}

//------------------------- Strategy Tester Self-Test ---------------//
bool IsTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

void UpdateTesterBarCounter()
{
   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt <= 0)
      return;

   if(bt != g_last_bar_time)
   {
      g_last_bar_time = bt;
      g_tester_bar_count++;
   }
}

void TesterSelfTest()
{
   if(!IsTester())
      return;

   if(!InpTesterSelfTestMode)
      return;

   UpdateTesterBarCounter();

   if(g_tester_signal_sent)
      return;

   if(g_tester_bar_count < InpTesterBarsBeforeTest)
      return;

   string action = UpperText(InpTesterTestAction);
   if(action != "BUY" && action != "SELL")
      action = "BUY";

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0;
   double tp1 = 0.0;
   double tp2 = 0.0;

   if(action == "BUY")
   {
      sl  = ask - InpTesterSLPoints  * _Point;
      tp1 = ask + InpTesterTP1Points * _Point;
      tp2 = ask + InpTesterTP2Points * _Point;
   }
   else
   {
      sl  = bid + InpTesterSLPoints  * _Point;
      tp1 = bid - InpTesterTP1Points * _Point;
      tp2 = bid - InpTesterTP2Points * _Point;
   }

   string alert_id = "TESTER_" + action + "_" + IntegerToString((int)TimeCurrent());
   bool ok = ExecuteMarketOrder(action, alert_id, sl, tp1, tp2, "MT5 Strategy Tester self-test. Not a strategy signal.");

   g_tester_signal_sent = true;
   SaveLastAlertId(alert_id);

   if(!ok)
      WriteLog("ERROR", action, alert_id, "Tester self-test did not open trade. Check Journal/Experts retcode.");
}

//------------------------- Status Comment --------------------------//
void DrawStatus()
{
   string mode = IsTester() ? "STRATEGY TESTER" : "LIVE/DEMO CHART";
   string status = "ABED TV EXECUTOR PRO v1.0.1\n";
   status += "Mode: " + mode + "\n";
   status += "Symbol: " + _Symbol + " | Spread: " + DoubleToString(CurrentSpreadPoints(), 1) + " pts\n";
   status += "Open Trades: " + IntegerToString(CountOpenPositions(-1)) + " | Today Trades: " + IntegerToString(TodayEntryTradesCount()) + "\n";
   status += "Last Alert: " + g_last_alert_id + "\n";

   if(IsTester())
      status += "Tester Self-Test: " + (InpTesterSelfTestMode ? "ON" : "OFF") + " | Sent: " + (g_tester_signal_sent ? "YES" : "NO") + "\n";
   else
      status += "Waiting file: Common\\Files\\" + InpSignalFileName + "\n";

   Comment(status);
}

//------------------------- MT5 Events ------------------------------//
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   LoadLastAlertId();
   EnsureLogHeader();

   int timer_seconds = InpTimerSeconds;
   if(timer_seconds < 1)
      timer_seconds = 1;
   EventSetTimer(timer_seconds);

   WriteLog("INIT", "", "", "EA started v1.0.1. Waiting for " + InpSignalFileName + " | LastAlert=" + g_last_alert_id);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   WriteLog("DEINIT", "", "", "EA stopped. reason=" + IntegerToString(reason));
}

void OnTimer()
{
   g_last_timer_run = TimeCurrent();

   if(!IsTester())
   {
      string json = ReadWholeFile(InpSignalFileName);
      if(json != "")
         ProcessSignal(json);
   }

   DrawStatus();
}

void OnTick()
{
   TesterSelfTest();
   DrawStatus();
}
//+------------------------------------------------------------------+
