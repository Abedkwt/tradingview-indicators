//+------------------------------------------------------------------+
//| ABED_XAUUSD_TV_EXECUTOR_PRO_v1_0.mq5                             |
//| TradingView JSON file executor for MT5                           |
//| Phase 1: Small, safe, local-file executor                         |
//|                                                                  |
//| Purpose:                                                         |
//|  - Read one JSON signal file from MT5 Common Files folder          |
//|  - Validate secret, symbol, spread, duplicates, limits             |
//|  - Execute BUY / SELL / CLOSE_ALL / CLOSE_BUY / CLOSE_SELL         |
//|  - Use fixed lot by default                                       |
//|  - Write a CSV execution log                                      |
//|                                                                  |
//| IMPORTANT: This EA is an executor only. It does not generate       |
//| trading signals. TradingView/Pine remains the strategy brain.      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "ABED XAUUSD TradingView Executor PRO v1.0 - local JSON file executor"

#include <Trade/Trade.mqh>

CTrade trade;

//------------------------- Inputs ----------------------------------//
input string InpSecret                  = "ABED_SECRET_2026";
input string InpSignalFileName          = "ABED_TV_SIGNAL.json";
input string InpLastAlertFileName       = "ABED_TV_LAST_ALERT_ID.txt";
input string InpLogFileName             = "ABED_TV_EXECUTOR_LOG.csv";
input bool   InpUseCommonFilesFolder    = true;

input string InpAllowedSymbolText       = "XAU";       // Broker symbol must contain this text, e.g. XAU / GOLD
input bool   InpRequireAlertSymbolMatch = false;       // false is safer for brokers using XAUUSDm, GOLD, etc.

input bool   InpEnableTrading           = true;
input bool   InpAllowBuy                = true;
input bool   InpAllowSell               = true;
input bool   InpCloseOppositeBeforeOpen = false;

input bool   InpUseFixedLot             = true;
input double InpFixedLot                = 0.01;
input double InpRiskPercent             = 0.50;        // Used only if InpUseFixedLot=false

input int    InpMaxSpreadPoints         = 350;         // Broker points; adjust after seeing live spread
input int    InpSlippagePoints          = 30;
input int    InpMaxOpenTrades           = 1;
input int    InpMaxTradesPerDay         = 3;
input double InpMaxDailyLossPercent     = 2.0;         // 0 = disabled

input int    InpTimerSeconds            = 2;
input long   InpMagicNumber             = 26060201;
input bool   InpUseTP2AsMainTP          = true;        // true = use tp2 as order TP, false = use tp1
input bool   InpDeleteSignalAfterProcess= false;       // false keeps file for review

//------------------------- State -----------------------------------//
string g_last_alert_id = "";
datetime g_last_timer_run = 0;

//------------------------- Helpers ---------------------------------//
string TrimText(string s)
{
   s = StringTrimLeft(s);
   s = StringTrimRight(s);
   return s;
}

string UpperText(string s)
{
   StringToUpper(s);
   return s;
}

bool IsCommon()
{
   return InpUseCommonFilesFolder;
}

int FileFlagsRead()
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

int FileFlagsWrite()
{
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

int FileFlagsAppendCsv()
{
   int flags = FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI;
   if(IsCommon())
      flags |= FILE_COMMON;
   return flags;
}

string ReadWholeFile(const string file_name)
{
   int handle = FileOpen(file_name, FileFlagsRead());
   if(handle == INVALID_HANDLE)
      return "";

   string data = "";
   int file_size = (int)FileSize(handle);

   if(file_size > 0)
      data = FileReadString(handle, file_size);

   FileClose(handle);
   return data;
}

bool WriteWholeFile(const string file_name, const string text)
{
   int handle = FileOpen(file_name, FileFlagsWrite());
   if(handle == INVALID_HANDLE)
      return false;

   FileWriteString(handle, text);
   FileClose(handle);
   return true;
}

void EnsureLogHeader()
{
   int handle = FileOpen(InpLogFileName, FileFlagsAppendCsv());
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

   int handle = FileOpen(InpLogFileName, FileFlagsAppendCsv());
   if(handle == INVALID_HANDLE)
   {
      Print("LOG OPEN FAILED: ", message);
      return;
   }

   FileSeek(handle, 0, SEEK_END);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spread_points = 0.0;
   if(_Point > 0.0)
      spread_points = (ask - bid) / _Point;

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             level,
             _Symbol,
             action,
             alert_id,
             message,
             DoubleToString(bid, _Digits),
             DoubleToString(ask, _Digits),
             DoubleToString(spread_points, 1),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));

   FileClose(handle);
   Print(level, " | ", action, " | ", alert_id, " | ", message);
}

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
   while(start < StringLen(json))
   {
      string ch = StringSubstr(json, start, 1);
      if(ch != " " && ch != "\t" && ch != "\r" && ch != "\n")
         break;
      start++;
   }

   if(start >= StringLen(json))
      return "";

   bool quoted = (StringSubstr(json, start, 1) == "\"");

   if(quoted)
   {
      int endq = StringFind(json, "\"", start + 1);
      if(endq < 0)
         return "";
      return StringSubstr(json, start + 1, endq - start - 1);
   }

   int end_comma = StringFind(json, ",", start);
   int end_brace = StringFind(json, "}", start);

   int end = -1;
   if(end_comma >= 0 && end_brace >= 0)
      end = MathMin(end_comma, end_brace);
   else if(end_comma >= 0)
      end = end_comma;
   else if(end_brace >= 0)
      end = end_brace;
   else
      end = StringLen(json);

   return TrimText(StringSubstr(json, start, end - start));
}

string JsonString(const string json, const string key, const string default_value = "")
{
   string value = JsonRawValue(json, key);
   if(value == "")
      return default_value;
   return TrimText(value);
}

double JsonDouble(const string json, const string key, const double default_value = 0.0)
{
   string value = JsonRawValue(json, key);
   value = TrimText(value);
   if(value == "")
      return default_value;
   return StringToDouble(value);
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

   // Allows XAUUSDm vs XAUUSD or GOLD vs XAU when the text is contained.
   if(StringFind(chart_sym, alert_sym) >= 0 || StringFind(alert_sym, chart_sym) >= 0)
      return true;

   return false;
}

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
   double spread = CurrentSpreadPoints();
   return (spread <= InpMaxSpreadPoints);
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
   if(step_vol == 0.1)
      digits = 1;
   else if(step_vol == 0.01)
      digits = 2;
   else if(step_vol == 0.001)
      digits = 3;
   else if(step_vol == 0.0001)
      digits = 4;

   return NormalizeDouble(volume, digits);
}

double CalculateRiskLot(const double entry_price, const double sl_price)
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

   double lot = risk_money / loss_per_lot;
   return NormalizeVolume(lot);
}

int CountOpenPositions(const int direction_filter = -1)
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
         WriteLog("ERROR", "CLOSE", "", reason + " failed | retcode=" + IntegerToString((int)trade.ResultRetcode()));
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

   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stops_level * _Point;

   string act = UpperText(action);

   if(act == "BUY")
   {
      if(sl <= 0.0 || sl >= entry)
      {
         why_not = "Invalid BUY SL";
         return false;
      }
      if(tp > 0.0 && tp <= entry)
      {
         why_not = "Invalid BUY TP";
         return false;
      }
   }
   else if(act == "SELL")
   {
      if(sl <= 0.0 || sl <= entry)
      {
         why_not = "Invalid SELL SL";
         return false;
      }
      if(tp > 0.0 && tp >= entry)
      {
         why_not = "Invalid SELL TP";
         return false;
      }
   }

   if(min_distance > 0.0)
   {
      if(MathAbs(entry - sl) < min_distance)
      {
         why_not = "SL too close to market";
         return false;
      }
      if(tp > 0.0 && MathAbs(entry - tp) < min_distance)
      {
         why_not = "TP too close to market";
         return false;
      }
   }

   return true;
}

void LoadLastAlertId()
{
   string loaded = ReadWholeFile(InpLastAlertFileName);
   loaded = TrimText(loaded);
   g_last_alert_id = loaded;
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

   int flags = FILE_COMMON;
   if(!IsCommon())
      flags = 0;

   FileDelete(InpSignalFileName, flags);
}

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

   if(!SymbolAllowedByChart())
   {
      WriteLog("BLOCK", act, alert_id, "Chart symbol is not allowed: " + _Symbol);
      return false;
   }

   if(!SpreadOK())
   {
      WriteLog("BLOCK", act, alert_id, "Spread too high: " + DoubleToString(CurrentSpreadPoints(), 1));
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
      WriteLog("BLOCK", act, alert_id, stop_reason);
      return false;
   }

   double lot = CalculateRiskLot(entry, sl);
   if(lot <= 0.0)
   {
      WriteLog("BLOCK", act, alert_id, "Lot calculation failed");
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool sent = false;
   string comment = "ABED_TV_EXEC_v1|" + alert_id;

   if(act == "BUY")
      sent = trade.Buy(lot, _Symbol, 0.0, sl, tp, comment);
   else if(act == "SELL")
      sent = trade.Sell(lot, _Symbol, 0.0, sl, tp, comment);

   if(sent)
   {
      string msg = "ORDER SENT lot=" + DoubleToString(lot, 2) +
                   " sl=" + DoubleToString(sl, _Digits) +
                   " tp=" + DoubleToString(tp, _Digits) +
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
   {
      // If TradingView does not provide alert_id, create a deterministic fallback from action/timeframe/prices.
      alert_id = action + "_" + timeframe + "_" + DoubleToString(sl, _Digits) + "_" +
                 DoubleToString(tp1, _Digits) + "_" + DoubleToString(tp2, _Digits);
   }

   if(alert_id == g_last_alert_id)
   {
      // Silent duplicate skip to avoid log spam.
      return;
   }

   if(!AlertSymbolMatches(alert_symbol))
   {
      WriteLog("BLOCK", action, alert_id, "Alert symbol does not match chart symbol. alert=" + alert_symbol + " chart=" + _Symbol);
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
      WriteLog("BLOCK", action, alert_id, "Unsupported action. v1.0 supports BUY, SELL, CLOSE_ALL, CLOSE_BUY, CLOSE_SELL");
      SaveLastAlertId(alert_id);
      return;
   }

   bool ok = ExecuteMarketOrder(action, alert_id, sl, tp1, tp2, reason);

   // Save alert ID even when blocked to prevent repeated execution attempts from same bad file.
   SaveLastAlertId(alert_id);

   if(ok)
      DeleteSignalFileIfNeeded();
}

//------------------------- MT5 Events -------------------------------//
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   LoadLastAlertId();
   EnsureLogHeader();

   if(InpTimerSeconds < 1)
      EventSetTimer(1);
   else
      EventSetTimer(InpTimerSeconds);

   WriteLog("INIT", "", "", "EA started. Waiting for " + InpSignalFileName + " | LastAlert=" + g_last_alert_id);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   WriteLog("DEINIT", "", "", "EA stopped. reason=" + IntegerToString(reason));
}

void OnTimer()
{
   g_last_timer_run = TimeCurrent();

   string json = ReadWholeFile(InpSignalFileName);
   if(json == "")
      return;

   ProcessSignal(json);
}

void OnTick()
{
   // Phase 1 intentionally does nothing on tick.
   // Trade management such as TP1 partial, BE, and trailing will be added in v1.1 after execution is confirmed stable.
}
//+------------------------------------------------------------------+
