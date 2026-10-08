//+------------------------------------------------------------------+
//| ExampleBridgeEA.mq5                                               |
//|                                                                    |
//| Auto-discovery bridge between an MT5 terminal and vps_agent.       |
//|                                                                    |
//| WHAT CHANGED FROM THE MANUAL-CONFIG VERSION:                       |
//|   - WatchedSymbolsCsv now takes "SYMBOL@TIMEFRAME" entries, e.g.   |
//|     "EURUSD@M5,GBPUSD@M12,EURUSD@H1,XAUUSD,XAGUSD@H1". Colon (:)   |
//|     is NOT used as the delimiter because it's illegal in Windows   |
//|     filenames -- "@" is used instead, both here and in filenames.  |
//|     Omitting "@TIMEFRAME" on any entry (e.g. "XAUUSD" above)       |
//|     defaults that one entry to this chart's own timeframe.         |
//|   - One EA instance can now genuinely serve several TIMEFRAMES of  |
//|     the SAME symbol at once (not just several symbols on one       |
//|     timeframe) -- CopyRates() is called with each target's own     |
//|     ENUM_TIMEFRAMES, not this chart's _Period, so "EURUSD@M5" and  |
//|     "EURUSD@H1" on the same running EA both export correctly.      |
//|     There's still no MT5 way to receive live ticks for a timeframe |
//|     other than the chart's own, so bars for a non-chart timeframe  |
//|     are only checked for a close on this chart's own tick cadence  |
//|     -- fine for anything M1 and above, just not tick-perfect.      |
//|   - All files (OHLC, commands, results, status, and a new          |
//|     meta.json heartbeat) are now written to the shared             |
//|     Common\Files folder (FILE_COMMON), not this terminal's own     |
//|     private MQL5\Files -- under:                                   |
//|       Common\Files\<InpBaseFolder>\<terminal_id>\<SYMBOL>_<TF>\    |
//|     where terminal_id is deterministic: AccountLogin_AccountServer |
//|     (sanitized). This is what lets several MT4/MT5 terminals for   |
//|     different accounts, and several symbol/timeframe combos each,  |
//|     all land in ONE folder tree vps_agent can auto-discover --     |
//|     no more hand-editing config.yaml's terminals: list per combo.  |
//|   - meta.json (one per terminal, at the <terminal_id>\ level, not  |
//|     per symbol/timeframe) is rewritten every telemetry tick with   |
//|     this terminal's identity, account info, and the full, absolute |
//|     (TERMINAL_COMMONDATA_PATH-based) file paths for every symbol/  |
//|     timeframe target it's currently serving. vps_agent's discovery |
//|     loop scans for these files and builds its terminal list from   |
//|     them automatically -- see vps_agent/README.md's "Auto-         |
//|     discovery" section.                                            |
//|                                                                    |
//| Everything else (command/result JSON-lines shapes, OPEN/CLOSE      |
//| handling, hedging-mode requirement, retry/filling-mode logic) is   |
//| unchanged from the manual-config version -- see git history if you |
//| need that version's header comments on the MT4->MT5 port itself.   |
//|                                                                    |
//| Still NOT a substitute for your own testing: no partial-fill       |
//| handling, no requote-specific backoff tuning beyond the plain      |
//| retry loop, no risk management beyond what the brain sends.        |
//| Harden further before real capital.                                |
//+------------------------------------------------------------------+
#property strict

#include "MTStats.mqh"   // fleet toolkit: writes stats_<name>.csv for watchdog/rotate/status page

// How this EA reports the account environment in meta.json. Auto (default) reads MT5's ACCOUNT_TRADE_MODE.
// The override changes ONLY the reported "environment" metadata -- it does not change the broker account,
// the agent's relay registration (config.yaml `environment`), or whether trading is enabled.
enum ENUM_BRIDGE_ENVIRONMENT
  {
   BRIDGE_ENV_AUTO = 0,   // Auto (detect from account)
   BRIDGE_ENV_DEMO = 1,   // Report demo
   BRIDGE_ENV_LIVE = 2    // Report live
  };
ENUM_BRIDGE_ENVIRONMENT InpEnvironment = BRIDGE_ENV_LIVE; // environment written to meta.json (charts sharing one account's meta.json should use the same value)
input string InpBaseFolder  = "agentic_bridge"; // subfolder under Common\Files this whole system lives under -- must match vps_agent's discovery.base_folder
input string WatchedSymbolsCsv = ""; // blank = watch only this chart's own symbol@this chart's own timeframe. Else "SYMBOL@TF,SYMBOL@TF,..." -- e.g. "EURUSD@M5,GBPUSD@M12,EURUSD@H1,XAUUSD,XAGUSD@H1" (a bare "XAUUSD" with no @TF defaults to this chart's timeframe)
input string InpFleetName   = "";   // MUST equal the "name" column in accounts.csv (e.g. acc1). Blank = fleet stats disabled
input double DefaultLots    = 0.10;
input int    Slippage       = 50;    // points of tolerance (request.deviation) on OrderSend
input bool   InpUseAsCandleHistory = true; // "use as candle history": true = this terminal answers BACKFILL_HISTORY requests (sends old candles to the brain). false = it ignores them and sends NO backfill history (live new-bar candles and trading are unaffected). Set false on terminals whose broker history you do not want the brain to train on.
input double InpMaxSpreadPips = 0.0; // spread guard: refuse an OPEN while (ask-bid) is wider than this many pips. 0 = off. The OPEN command's "max_spread_pips" (set per scope in the vps_agent dashboard) overrides it. Never applies to CLOSE.
input int    MaxRetries     = 3;    // attempts before giving up on a single command
input int    RetryDelayMs   = 250;  // pause between retries
input int    TelemetryIntervalSeconds = 10;  // how often to rewrite the telemetry files and meta.json heartbeat
input bool   InpTradeEventFeed = true;  // write EVERY order action on this account (opens, closes incl. SL/TP/stop-out hits, partial closes, pending orders, SL/TP edits -- manual trades too) to <base>\\<account>\\trade_events.jsonl. vps_agent turns that into per-account Telegram notifications (set the bot token + chat id in the vps_agent dashboard). false = no feed.
input int    WatchlistCheckIntervalSeconds = 5;  // how often OnTick re-reads watchlist.json for dashboard-driven changes

struct SymbolTarget
  {
   string          symbol;
   ENUM_TIMEFRAMES timeframe;
   string          tfLabel;      // e.g. "M5", "H1" -- used in folder names and meta.json
   string          dir;          // relative to Common\Files, e.g. "agentic_bridge\\123_Broker-Demo\\EURUSD_M5\\"
   string          ohlcPath;
   string          historyPath;  // backfill export -- see ExecuteBackfillHistory
   string          commandPath;
   string          resultPath;
   string          accountPath;
   string          ordersPath;
   string          marketPath;
   string          closedHistoryPath;
   string          offsetPath;   // persists commandReadOffset across EA/terminal restarts -- see LoadCommandOffset
   datetime        lastBarTime;
   int             commandReadOffset;
   int             knownMagics[256]; // fixed-size (not dynamic) so SymbolTarget stays copyable in MQL5;
   int             knownMagicCount;  // magic numbers this target has ever OPENed under -- see RememberMagic /
                                   // LoadKnownMagicsFromCommandHistory. Used by ExportOrdersStatus and
                                   // ExportClosedHistory to scope each target's reported positions to the
                                   // ones IT actually opened, instead of every position on the account that
                                   // happens to share its symbol (multiple timeframe targets on the same
                                   // symbol would otherwise all report each other's positions).
  };

SymbolTarget targets[];
datetime lastTelemetryTime = 0;
string   g_terminalId;
string   g_baseDir;
string   g_tradeEventsPath;      // <base>\<terminal_id>\trade_events.jsonl -- account-wide order-action feed (see OnTradeTransaction)
string   g_watchlistPath;         // <base>\<terminal_id>\watchlist.json -- dashboard-managed target list
string   g_lastWatchlistContent = "";
datetime g_lastWatchlistCheck = 0;

int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: this account is not in hedging mode. The brain tracks one Position per "
            "(strategy, symbol) by broker ticket; in netting mode, two strategies trading the same "
            "symbol get merged into a single broker position, breaking that assumption and making a "
            "CLOSE-by-ticket potentially close/reduce the wrong strategy's share. See the header "
            "comment above for details.");

   g_terminalId = Sanitize(IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + AccountInfoString(ACCOUNT_SERVER));
   g_baseDir = InpBaseFolder + "\\" + g_terminalId + "\\";
   g_watchlistPath = g_baseDir + "watchlist.json";
   g_tradeEventsPath = g_baseDir + "trade_events.jsonl";
   FolderCreate(g_baseDir, FILE_COMMON);

   BuildTargets();
   for(int i = 0; i < ArraySize(targets); i++)
     {
      FolderCreate(targets[i].dir, FILE_COMMON);
      // Load (or, on a target's very first-ever run, initialize) the
      // persisted command-file read offset BEFORE anything else touches
      // commands.jsonl -- see LoadCommandOffset for why this must not
      // default to 0 on a restart.
      targets[i].commandReadOffset = LoadCommandOffset(targets[i]);
      // Rescan this target's own command history (independent of the read
      // offset above -- see LoadKnownMagicsFromCommandHistory) so the
      // per-target magic scoping in ExportOrdersStatus/ExportClosedHistory
      // works immediately on this restart, not just for OPENs from here on.
      LoadKnownMagicsFromCommandHistory(targets[i]);
      if(!SymbolSelect(targets[i].symbol, true))
        {
         Print("WARNING: could not add ", targets[i].symbol, " to Market Watch -- this terminal may not "
               "recognize that symbol (check spelling/broker suffix). OHLC export and trading for it will "
               "silently fail until this is fixed.");
         continue;
        }
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(targets[i].symbol, targets[i].timeframe, 0, 1, rates) == 1)
         targets[i].lastBarTime = rates[0].time;
     }
   if(InpFleetName != "")
     {
      MTStats_Init(InpFleetName);
      EventSetTimer(60);
      MTStats_Write();
     }
   WriteHeartbeat();  // so meta.json exists immediately, not just after the first TelemetryIntervalSeconds
   return(INIT_SUCCEEDED);
  }

//--- reads a small text file (Common\Files) in full, as one string. Used  --
//--- for watchlist.json, which both this EA and the vps_agent dashboard   --
//--- read/write as a single compact JSON line. -----------------------------
string ReadFileAsString(string path)
  {
   if(!FileIsExist(path, FILE_COMMON))
      return "";
   int handle = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return "";
   string content = "";
   while(!FileIsEnding(handle))
     {
      content += FileReadString(handle);
      if(!FileIsEnding(handle))
         content += "\n";
     }
   FileClose(handle);
   return content;
  }

//--- tiny JSON string-array parser: pulls every "..."-quoted value out of --
//--- a top-level array like ["EURUSD@M10","BTCUSD@M30"], in order. Doesn't --
//--- handle escaped quotes inside entries -- not needed for symbol names. --
int ParseJsonStringArray(string json, string &out[])
  {
   int count = 0;
   ArrayResize(out, 0);
   int len = StringLen(json);
   int i = 0;
   while(i < len)
     {
      int q1 = StringFind(json, "\"", i);
      if(q1 < 0)
         break;
      int q2 = StringFind(json, "\"", q1 + 1);
      if(q2 < 0)
         break;
      ArrayResize(out, count + 1);
      out[count] = StringSubstr(json, q1 + 1, q2 - q1 - 1);
      count++;
      i = q2 + 1;
     }
   return count;
  }

//--- writes watchlist.json from a CSV-derived entry list -- called once to --
//--- seed the dashboard the first time an EA with no watchlist.json yet    --
//--- starts up from its (legacy) WatchedSymbolsCsv input. -------------------
void WriteWatchlistFile(string &entries[], int n)
  {
   string json = "[";
   for(int i = 0; i < n; i++)
     {
      if(i > 0)
         json += ",";
      json += "\"" + entries[i] + "\"";
     }
   json += "]";
   int handle = FileOpen(g_watchlistPath, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileWrite(handle, json);
   FileClose(handle);
   g_lastWatchlistContent = json;
  }

//--- builds one SymbolTarget from a single "SYMBOL@TF" (or bare "SYMBOL")  --
//--- entry. Pure/stateless -- caller decides lastBarTime/commandReadOffset. -
SymbolTarget MakeTarget(string entry)
  {
   StringTrimLeft(entry);
   StringTrimRight(entry);

   string          symbol;
   ENUM_TIMEFRAMES tf;
   int atPos = StringFind(entry, "@");
   if(atPos < 0)
     {
      symbol = entry;
      tf = _Period;
     }
   else
     {
      symbol = StringSubstr(entry, 0, atPos);
      tf = StringToTimeframe(StringSubstr(entry, atPos + 1));
     }
   StringTrimLeft(symbol);
   StringTrimRight(symbol);

   SymbolTarget t;
   t.symbol  = symbol;
   t.timeframe = tf;
   t.tfLabel = TimeframeToLabel(tf);
   t.dir     = g_baseDir + symbol + "_" + t.tfLabel + "\\";
   t.ohlcPath    = t.dir + "ohlc.csv";
   t.historyPath = t.dir + "history_backfill.csv";
   t.commandPath = t.dir + "commands.jsonl";
   t.resultPath  = t.dir + "results.jsonl";
   t.accountPath = t.dir + "account.json";
   t.ordersPath  = t.dir + "orders.json";
   t.marketPath  = t.dir + "market.json";
   t.closedHistoryPath = t.dir + "closed_history.json";
   t.offsetPath  = t.dir + "commands.offset";
   t.lastBarTime = 0;
   t.commandReadOffset = 0;
   t.knownMagicCount = 0;
   return t;
  }

//--- current size (bytes) of a Common\Files file, or 0 if it doesn't exist -
long GetFileSizeCommon(string path)
  {
   if(!FileIsExist(path, FILE_COMMON))
      return 0;
   int handle = FileOpen(path, FILE_READ|FILE_BIN|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return 0;
   long size = (long)FileSize(handle);
   FileClose(handle);
   return size;
  }

//--- loads target.commandReadOffset from its persisted offset file. -------
//--- THIS IS THE FIX for "reopening the terminal replays every past OPEN/  -
//--- CLOSE/BACKFILL command": commandReadOffset used to be hardcoded to 0  -
//--- on every EA (re)start, so ProcessPendingCommands() re-read commands   -
//--- .jsonl from byte zero and re-executed its entire history every time   -
//--- the EA reloaded (terminal restart, recompile, chart reattach, or the  -
//--- very first time a new symbol/timeframe target was added) -- vps_agent -
//--- never truncates that file, it only ever appends.                      -
//--- If no offset file exists yet for this target, this is either its      -
//--- first-ever run or its offset file was lost -- in both cases we start  -
//--- from the CURRENT end of commands.jsonl (skip whatever's already       -
//--- sitting there) rather than from 0, because blindly re-running old     -
//--- OPEN/CLOSE commands against a live account is far more dangerous      -
//--- than missing one that's already been superseded. --------------------
int LoadCommandOffset(SymbolTarget &target)
  {
   long fileSize = GetFileSizeCommon(target.commandPath);
   if(!FileIsExist(target.offsetPath, FILE_COMMON))
      return (int)fileSize;

   int handle = FileOpen(target.offsetPath, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return (int)fileSize;
   string s = FileReadString(handle);
   FileClose(handle);

   long persisted = StringToInteger(s);
   if(persisted < 0)
      persisted = 0;
   // commands.jsonl got rotated/truncated/replaced out from under us since
   // we last saved -- clamp instead of seeking past EOF (which would just
   // make the next FileIsEnding() true forever and silently stop reading).
   if(persisted > fileSize)
      persisted = fileSize;
   return (int)persisted;
  }

//--- persists target.commandReadOffset so the next EA start resumes here --
void SaveCommandOffset(SymbolTarget &target)
  {
   int handle = FileOpen(target.offsetPath, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileWrite(handle, IntegerToString(target.commandReadOffset));
   FileClose(handle);
  }

//--- adds `magic` to target.knownMagics if not already present. This is    --
//--- what lets ExportOrdersStatus/ExportClosedHistory scope a target's     --
//--- reported positions to the ones it actually opened -- see the field's  --
//--- comment on SymbolTarget for why that matters. --------------------------
void RememberMagic(SymbolTarget &target, int magic)
  {
   for(int i = 0; i < target.knownMagicCount; i++)
      if(target.knownMagics[i] == magic)
         return;
   int n = target.knownMagicCount;
   if(n >= 256)
     {
      Print("WARNING: ", target.symbol, " ", target.tfLabel, " already tracks 256 magic numbers -- not remembering ", magic);
      return;
     }
   target.knownMagics[n] = magic;
   target.knownMagicCount = n + 1;
  }

//--- seeds target.knownMagics from every OPEN this target has ever         --
//--- processed, by rescanning the target's own commands.jsonl in full --   --
//--- independent of commandReadOffset, which exists to avoid RE-EXECUTING  --
//--- old commands, not to avoid learning from them. Called once whenever a --
//--- target is created (fresh EA start, or a new watchlist entry) so the   --
//--- magic filter works immediately rather than only for OPENs processed   --
//--- after this run started. Cheap: commands.jsonl for one symbol/         --
//--- timeframe target is a small, bounded file, not the whole account's.   --
void LoadKnownMagicsFromCommandHistory(SymbolTarget &target)
  {
   if(!FileIsExist(target.commandPath, FILE_COMMON))
      return;
   int handle = FileOpen(target.commandPath, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) == 0)
         continue;
      if(JsonField(line, "action") != "OPEN")
         continue;
      string magicStr    = JsonField(line, "magic_number");
      string strategyId  = JsonField(line, "strategy_id");
      int magic = (StringLen(magicStr) > 0 && magicStr != "null")
                  ? (int)StringToInteger(magicStr)
                  : MagicFromStrategyId(strategyId);
      RememberMagic(target, magic);
     }
   FileClose(handle);
  }

//--- re-reads watchlist.json (throttled to WatchlistCheckIntervalSeconds)  -
//--- and reconciles targets[] against it if its content changed -- this is -
//--- what lets the vps_agent dashboard add/remove watched symbol/timeframe -
//--- targets on a running EA with no restart. ------------------------------
void CheckWatchlistForChanges()
  {
   if(TimeCurrent() - g_lastWatchlistCheck < WatchlistCheckIntervalSeconds)
      return;
   g_lastWatchlistCheck = TimeCurrent();

   if(!FileIsExist(g_watchlistPath, FILE_COMMON))
      return;  // nothing dashboard-managed yet -- keep whatever BuildTargets() loaded at OnInit

   string content = ReadFileAsString(g_watchlistPath);
   if(content == g_lastWatchlistContent)
      return;  // unchanged since last check

   g_lastWatchlistContent = content;

   string newEntries[];
   int n = ParseJsonStringArray(content, newEntries);
   if(n == 0)
     {
      Print("WARNING: watchlist.json changed but is empty/unparseable -- ignoring it and keeping the "
            "current ", ArraySize(targets), " target(s). Fix it from the vps_agent dashboard.");
      return;
     }
   ReconcileTargets(newEntries, n);
  }

//--- rebuilds targets[] from a new entry list, carrying over lastBarTime   -
//--- and commandReadOffset for any (symbol, timeframe) that already        -
//--- existed -- newly-added entries get their offset seeded from disk      -
//--- (LoadCommandOffset, same "start from EOF, not 0" rule as OnInit), and -
//--- entries no longer listed are simply dropped from memory (their files  -
//--- on disk are left alone in case they're re-added later). --------------
void ReconcileTargets(string &entries[], int n)
  {
   SymbolTarget newTargets[];
   ArrayResize(newTargets, n);
   int kept = 0, added = 0;

   for(int i = 0; i < n; i++)
     {
      SymbolTarget t = MakeTarget(entries[i]);

      int existingIdx = -1;
      for(int j = 0; j < ArraySize(targets); j++)
        {
         if(targets[j].symbol == t.symbol && targets[j].timeframe == t.timeframe)
           {
            existingIdx = j;
            break;
           }
        }

      if(existingIdx >= 0)
        {
         t.lastBarTime = targets[existingIdx].lastBarTime;
         t.commandReadOffset = targets[existingIdx].commandReadOffset;
         for(int km = 0; km < targets[existingIdx].knownMagicCount; km++)
            t.knownMagics[km] = targets[existingIdx].knownMagics[km];
         t.knownMagicCount = targets[existingIdx].knownMagicCount;
         kept++;
        }
      else
        {
         FolderCreate(t.dir, FILE_COMMON);
         if(!SymbolSelect(t.symbol, true))
            Print("WARNING: could not add ", t.symbol, " to Market Watch (new watchlist entry from dashboard) "
                  "-- check spelling/broker suffix.");
         MqlRates rates[];
         ArraySetAsSeries(rates, true);
         if(CopyRates(t.symbol, t.timeframe, 0, 1, rates) == 1)
            t.lastBarTime = rates[0].time;
         t.commandReadOffset = LoadCommandOffset(t);
         LoadKnownMagicsFromCommandHistory(t);
         added++;
        }
      newTargets[i] = t;
     }

   int removedCount = ArraySize(targets) - kept;
   // MQL5 does not allow assigning one struct array to another when the
   // struct has string members ("structure have objects and cannot be
   // copied") -- copy element-by-element instead, same as every other
   // struct assignment already done in this file (e.g. targets[i] = t;).
   ArrayResize(targets, ArraySize(newTargets));
   for(int k = 0; k < ArraySize(newTargets); k++)
      targets[k] = newTargets[k];
   if(added > 0 || removedCount > 0)
      Print("Watchlist reconciled from dashboard: ", added, " added, ", removedCount, " removed, ", kept,
            " unchanged. Now serving ", ArraySize(targets), " symbol/timeframe target(s).");
  }

//--- strips characters illegal in Windows folder names, spaces included --
string Sanitize(string s)
  {
   string bad = "\\/:*?\"<>| ";
   for(int i = 0; i < StringLen(bad); i++)
      StringReplace(s, StringSubstr(bad, i, 1), "_");
   return s;
  }

//--- "M5"/"m5" -> PERIOD_M5, etc. Unrecognized input falls back to this   --
//--- chart's own period rather than silently defaulting to something     --
//--- else, and prints a warning so the typo is visible. --------------------
ENUM_TIMEFRAMES StringToTimeframe(string s)
  {
   StringToUpper(s);
   if(s == "M1")  return PERIOD_M1;
   if(s == "M2")  return PERIOD_M2;
   if(s == "M3")  return PERIOD_M3;
   if(s == "M4")  return PERIOD_M4;
   if(s == "M5")  return PERIOD_M5;
   if(s == "M6")  return PERIOD_M6;
   if(s == "M10") return PERIOD_M10;
   if(s == "M12") return PERIOD_M12;
   if(s == "M15") return PERIOD_M15;
   if(s == "M20") return PERIOD_M20;
   if(s == "M30") return PERIOD_M30;
   if(s == "H1")  return PERIOD_H1;
   if(s == "H2")  return PERIOD_H2;
   if(s == "H3")  return PERIOD_H3;
   if(s == "H4")  return PERIOD_H4;
   if(s == "H6")  return PERIOD_H6;
   if(s == "H8")  return PERIOD_H8;
   if(s == "H12") return PERIOD_H12;
   if(s == "D1")  return PERIOD_D1;
   if(s == "W1")  return PERIOD_W1;
   if(s == "MN1" || s == "MN") return PERIOD_MN1;
   Print("WARNING: unrecognized timeframe \"", s, "\" in WatchedSymbolsCsv -- falling back to this chart's "
         "own period (", EnumToString(_Period), ")");
   return _Period;
  }

//--- reverse of the above, for folder/meta.json labels: PERIOD_M5 -> "M5" --
string TimeframeToLabel(ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);  // "PERIOD_M5"
   return StringSubstr(s, 7);    // strip the "PERIOD_" prefix
  }

//--- builds the initial list of (symbol, timeframe, file paths) this EA    --
//--- serves, at OnInit. watchlist.json (dashboard-managed) wins whenever   --
//--- it exists -- WatchedSymbolsCsv is now only the *bootstrap* default,   --
//--- used to seed watchlist.json the very first time an EA attaches with   --
//--- none yet. After that, the dashboard is the source of truth and this   --
//--- input is ignored (delete watchlist.json to fall back to it again).    --
void BuildTargets()
  {
   ArrayResize(targets, 0);
   string entries[];
   int n = 0;

   string fromDashboard = ReadFileAsString(g_watchlistPath);
   if(StringLen(fromDashboard) > 0)
      n = ParseJsonStringArray(fromDashboard, entries);
   if(n > 0)
     {
      g_lastWatchlistContent = fromDashboard;
      Print("Loaded ", n, " watched symbol/timeframe target(s) from watchlist.json (dashboard-managed).");
     }
   else
     {
      if(StringLen(WatchedSymbolsCsv) == 0)
        {
         ArrayResize(entries, 1);
         entries[0] = _Symbol;  // no @TF given -> MakeTarget defaults it to this chart's period
         n = 1;
        }
      else
         n = StringSplit(WatchedSymbolsCsv, ',', entries);
      WriteWatchlistFile(entries, n);  // seed the dashboard so it isn't empty on first run
     }

   ArrayResize(targets, n);
   for(int i = 0; i < n; i++)
      targets[i] = MakeTarget(entries[i]);
  }

void OnTimer()
  {
   MTStats_Write();
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
   CheckWatchlistForChanges();
   for(int i = 0; i < ArraySize(targets); i++)
      ExportNewBarIfClosed(targets[i]);
   for(int i = 0; i < ArraySize(targets); i++)
      ProcessPendingCommands(targets[i]);
   ExportTelemetryIfDue();
  }

//--- rewrite account + open-positions snapshots and the meta.json         --
//--- heartbeat on a timer, not every tick -----------------------------------
void ExportTelemetryIfDue()
  {
   if(TimeCurrent() - lastTelemetryTime < TelemetryIntervalSeconds)
      return;
   lastTelemetryTime = TimeCurrent();
   // Balance/equity/margin are account-wide, not per-symbol -- computed
   // once and written to every watched target's accountPath (matches what
   // you'd see if each symbol/timeframe really were its own EA instance on
   // the same login: identical numbers, reported from N places).
   string accountJson = BuildAccountStatusJson();
   for(int i = 0; i < ArraySize(targets); i++)
     {
      WriteJsonFile(targets[i].accountPath, accountJson);
      ExportOrdersStatus(targets[i]);
      ExportMarketStatus(targets[i]);
      ExportClosedHistory(targets[i]);
     }
   WriteHeartbeat();
  }

string BuildAccountStatusJson()
  {
   return StringFormat(
      "{\"balance\":%.2f,\"equity\":%.2f,\"margin\":%.2f,\"free_margin\":%.2f,\"currency\":\"%s\",\"leverage\":%d}",
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_MARGIN), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      AccountInfoString(ACCOUNT_CURRENCY), (int)AccountInfoInteger(ACCOUNT_LEVERAGE));
  }

//--- absolute path to this terminal's shared Common\Files\ folder, with --
//--- a trailing backslash and no double-slash regardless of whether     --
//--- TERMINAL_COMMONDATA_PATH itself already ends in one. ------------------
string CommonFilesRoot()
  {
   string p = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   if(StringLen(p) > 0 && StringGetCharacter(p, StringLen(p) - 1) == '\\')
      p = StringSubstr(p, 0, StringLen(p) - 1);
   return p + "\\Files\\";
  }

//--- backslashes need escaping to sit inside a JSON string value --------
string EscapeForJson(string s)
  {
   StringReplace(s, "\\", "\\\\");
   return s;
  }

//--- writes <base>\<terminal_id>\meta.json -- one per terminal (not per --
//--- symbol/timeframe), listing every target this EA instance serves so --
//--- vps_agent can auto-discover them instead of needing config.yaml    --
//--- hand-edited per symbol/timeframe. --------------------------------------
void WriteHeartbeat()
  {
   string absRoot = CommonFilesRoot();
   string detectedEnv = ((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO) ? "demo" : "live";
   string env = detectedEnv;
   if(InpEnvironment == BRIDGE_ENV_DEMO)
      env = "demo";
   else if(InpEnvironment == BRIDGE_ENV_LIVE)
      env = "live";

   string targetsJson = "[";
   for(int i = 0; i < ArraySize(targets); i++)
     {
      if(i > 0)
         targetsJson += ",";
      SymbolTarget t = targets[i];
      // symbol_ok: does this symbol exist on the broker's server? (false for a typo or a wrong suffix such as
      // EURUSD vs EURUSD.m). vps_agent's watchlist sync reads it to reject pairs that can never work.
      bool symIsCustom = false;
      bool symExists = SymbolExist(t.symbol, symIsCustom);
      targetsJson += StringFormat(
         "{\"symbol\":\"%s\",\"timeframe\":\"%s\","
         "\"ohlc_path\":\"%s\",\"command_path\":\"%s\",\"result_path\":\"%s\","
         "\"account_status_path\":\"%s\",\"orders_status_path\":\"%s\",\"market_status_path\":\"%s\","
         "\"closed_history_path\":\"%s\",\"symbol_ok\":%s}",
         t.symbol, t.tfLabel,
         EscapeForJson(absRoot + t.ohlcPath), EscapeForJson(absRoot + t.commandPath), EscapeForJson(absRoot + t.resultPath),
         EscapeForJson(absRoot + t.accountPath), EscapeForJson(absRoot + t.ordersPath), EscapeForJson(absRoot + t.marketPath),
         EscapeForJson(absRoot + t.closedHistoryPath),
         (symExists ? "true" : "false"));
     }
   targetsJson += "]";

   string json = StringFormat(
      "{\"terminal_id\":\"%s\",\"account_login\":%d,\"account_server\":\"%s\","
      "\"environment\":\"%s\",\"detected_environment\":\"%s\",\"currency\":\"%s\",\"leverage\":%d,"
      "\"platform\":\"MT5\",\"updated_at\":%d,\"trade_events_path\":\"%s\",\"targets\":%s}",
      g_terminalId, (int)AccountInfoInteger(ACCOUNT_LOGIN), AccountInfoString(ACCOUNT_SERVER),
      env, detectedEnv, AccountInfoString(ACCOUNT_CURRENCY), (int)AccountInfoInteger(ACCOUNT_LEVERAGE),
      (long)TimeCurrent(), (InpTradeEventFeed ? EscapeForJson(absRoot + g_tradeEventsPath) : ""), targetsJson);

   WriteJsonFile(g_baseDir + "meta.json", json);
  }

void WriteJsonFile(string path, string json)
  {
   int handle = FileOpen(path, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileWrite(handle, json);
   FileClose(handle);
  }

//+------------------------------------------------------------------+
//| Account-wide order-action feed -> trade_events.jsonl               |
//| One JSON object per line, appended; consumed by vps_agent's        |
//| telegram_notify.TradeEventNotifier. Raw ints are written for the   |
//| deal type/entry/reason enums (vps_agent maps them to words), so    |
//| this compiles on every MT5 build regardless of which DEAL_REASON_* |
//| constants it knows. Covers manual trades and server-side SL/TP.    |
//+------------------------------------------------------------------+
string JsonEscapeFull(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\t", " ");
   return s;
  }

void AppendTradeEvent(string json)
  {
   int handle = FileOpen(g_tradeEventsPath, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, json);
   FileClose(handle);
  }

string PriceText(string symbol, double price)
  {
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits < 0 || digits > 10)
      digits = 5;
   return DoubleToString(price, digits);
  }

void EmitDealEvent(ulong dealTicket)
  {
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;
   long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(dealType != DEAL_TYPE_BUY && dealType != DEAL_TYPE_SELL)
      return;   // balance / credit / charge lines are not order actions

   string symbol   = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long   entry    = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long   posId    = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   double volume   = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double price    = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double profit   = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double swap     = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   double comm     = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   long   magic    = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long   reason   = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   string comment  = HistoryDealGetString(dealTicket, DEAL_COMMENT);

   // The position this deal belongs to, if it still exists: gives the SL/TP of a fresh open, and the volume
   // LEFT after a partial close (0 when the deal closed it completely).
   double sl = 0.0, tp = 0.0, remaining = 0.0;
   if(PositionSelectByTicket((ulong)posId))
     {
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      remaining = PositionGetDouble(POSITION_VOLUME);
     }

   string json = StringFormat(
      "{\"event_id\":\"deal:%I64u\",\"kind\":\"DEAL\",\"emitted_at\":%I64d,\"login\":%I64d,\"currency\":\"%s\","
      "\"symbol\":\"%s\",\"deal_type\":%I64d,\"entry\":%I64d,\"position_id\":%I64d,\"volume\":%s,\"price\":%s,"
      "\"profit\":%s,\"swap\":%s,\"commission\":%s,\"magic\":%I64d,\"reason\":%I64d,"
      "\"sl\":%s,\"tp\":%s,\"remaining_volume\":%s,\"comment\":\"%s\"}",
      dealTicket, (long)TimeGMT(), AccountInfoInteger(ACCOUNT_LOGIN), JsonEscapeFull(AccountInfoString(ACCOUNT_CURRENCY)),
      JsonEscapeFull(symbol), dealType, entry, posId,
      DoubleToString(volume, 2), PriceText(symbol, price),
      DoubleToString(profit, 2), DoubleToString(swap, 2), DoubleToString(comm, 2), magic, reason,
      PriceText(symbol, sl), PriceText(symbol, tp), DoubleToString(remaining, 2), JsonEscapeFull(comment));
   AppendTradeEvent(json);
  }

void EmitRequestEvent(const MqlTradeRequest &req, const MqlTradeResult &res)
  {
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
      return;   // rejected / failed requests are not order actions
   string kind = "";
   switch(req.action)
     {
      case TRADE_ACTION_PENDING: kind = "PENDING_PLACED";   break;
      case TRADE_ACTION_SLTP:    kind = "SLTP_MODIFIED";    break;
      case TRADE_ACTION_MODIFY:  kind = "PENDING_MODIFIED"; break;
      case TRADE_ACTION_REMOVE:  kind = "PENDING_REMOVED";  break;
      default:
         return;   // TRADE_ACTION_DEAL (market) is reported by its DEAL_ADD, which carries the real fill
     }
   string json = StringFormat(
      "{\"event_id\":\"req:%u:%I64u:%I64d\",\"kind\":\"%s\",\"emitted_at\":%I64d,\"login\":%I64d,\"currency\":\"%s\","
      "\"symbol\":\"%s\",\"order_type\":%d,\"volume\":%s,\"price\":%s,\"sl\":%s,\"tp\":%s,"
      "\"order\":%I64u,\"position_id\":%I64u,\"magic\":%I64d,\"comment\":\"%s\"}",
      res.request_id, res.order, (long)TimeGMT(), kind, (long)TimeGMT(), AccountInfoInteger(ACCOUNT_LOGIN),
      JsonEscapeFull(AccountInfoString(ACCOUNT_CURRENCY)),
      JsonEscapeFull(req.symbol), (int)req.type, DoubleToString(req.volume, 2), PriceText(req.symbol, req.price),
      PriceText(req.symbol, req.sl), PriceText(req.symbol, req.tp),
      res.order, req.position, (long)req.magic, JsonEscapeFull(req.comment));
   AppendTradeEvent(json);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!InpTradeEventFeed)
      return;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      EmitDealEvent(trans.deal);
      return;
     }
   if(trans.type == TRADE_TRANSACTION_REQUEST)
      EmitRequestEvent(request, result);
  }

void ExportMarketStatus(SymbolTarget &target)
  {
   MqlTick tick;
   double spread = 0.0;
   if(SymbolInfoTick(target.symbol, tick))
      spread = tick.ask - tick.bid;  // raw price units -- the brain interprets this itself, no pip conversion here
   string json = StringFormat("{\"spread\":%.5f}", spread);
   WriteJsonFile(target.marketPath, json);
  }

void ExportOrdersStatus(SymbolTarget &target)
  {
   int handle = FileOpen(target.ordersPath, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;

   string json = "[";
   bool first = true;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != target.symbol)
         continue;
      // Symbol alone isn't a boundary: several targets can watch the same
      // symbol on different timeframes, and MT5 positions don't carry a
      // timeframe -- only a magic number does. Once we've learned at least
      // one magic this target actually opened under (see knownMagics), only
      // report positions carrying one of those magics; otherwise every
      // same-symbol target would show every other one's open positions too.
      // Before any magic is known yet (brand new target, nothing opened
      // through it so far) fall back to symbol-only, so a pre-existing
      // manual position on this symbol still shows up somewhere.
      if(target.knownMagicCount > 0)
        {
         long posMagic = PositionGetInteger(POSITION_MAGIC);
         bool magicKnown = false;
         for(int m = 0; m < target.knownMagicCount; m++)
            if(target.knownMagics[m] == posMagic)
              {
               magicKnown = true;
               break;
              }
         if(!magicKnown)
            continue;
        }
      if(!first)
         json += ",";
      first = false;
      long posType = PositionGetInteger(POSITION_TYPE);
      string orderType = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      // Floating PnL here is profit+swap only (no commission) -- this is a
      // live, still-open position, not a closed deal history to sum. The
      // CLOSE path below does include commission for the final reported figure.
      json += StringFormat(
         "{\"ticket\":\"%I64u\",\"symbol\":\"%s\",\"order_type\":\"%s\",\"volume\":%.2f,"
         "\"open_price\":%.5f,\"current_price\":%.5f,\"stop_loss\":%.5f,\"take_profit\":%.5f,"
         "\"profit\":%.2f,\"magic_number\":%d,\"status\":\"OPEN\"}",
         ticket, PositionGetString(POSITION_SYMBOL), orderType, PositionGetDouble(POSITION_VOLUME),
         PositionGetDouble(POSITION_PRICE_OPEN), currentPrice,
         PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), pnl, (long)PositionGetInteger(POSITION_MAGIC));
     }
   json += "]";
   FileWrite(handle, json);
   FileClose(handle);
  }

//--- Rewrites target.closedHistoryPath with the most recent closed        --
//--- positions on this symbol (newest first), for two consumers:          --
//--- (1) vps_agent's dashboard, to show real closed-trade history instead --
//--- of only currently-open positions (ExportOrdersStatus only ever       --
//--- reports OPEN); (2) the lot-override martingale engine, which needs   --
//--- ground truth on whether the LAST closed trade on this symbol/magic   --
//--- won or lost -- it must read broker history, never assume its own    --
//--- in-memory state (same reasoning as GetLastClosedTradeLots() in the   --
//--- standalone sample strategy this was modeled on). Full rewrite each   --
//--- telemetry tick, same convention as ExportOrdersStatus -- simpler     --
//--- than tailing an append-only file and cheap at this scan window.      --
input int    InpClosedHistoryLookbackDays = 30;   // how far back to scan for closed deals
input int    InpClosedHistoryMaxEntries   = 200;   // cap on how many closed trades to keep in the file

void ExportClosedHistory(SymbolTarget &target)
  {
   datetime from = TimeCurrent() - InpClosedHistoryLookbackDays * 86400;
   if(!HistorySelect(from, TimeCurrent()))
      return;

   int total = HistoryDealsTotal();
   string entries[];
   ArrayResize(entries, 0);
   int count = 0;

   // Walk newest-first so the MaxEntries cap keeps the MOST RECENT trades,
   // not the oldest ones in the lookback window.
   for(int i = total - 1; i >= 0 && count < InpClosedHistoryMaxEntries; i--)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      // Only a position-CLOSING deal represents a finished trade -- the
      // matching OPEN deal (DEAL_ENTRY_IN) for the same position is
      // skipped here so each closed trade appears exactly once.
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != target.symbol)
         continue;
      // Same magic-scoping as ExportOrdersStatus (see its comment) -- without
      // it, closed trades from another timeframe target on this same symbol
      // would show up here too, and the lot-override martingale engine reads
      // this file believing it's ONLY this target's own history.
      if(target.knownMagicCount > 0)
        {
         long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         bool magicKnown = false;
         for(int m = 0; m < target.knownMagicCount; m++)
            if(target.knownMagics[m] == dealMagic)
              {
               magicKnown = true;
               break;
              }
         if(!magicKnown)
            continue;
        }

      long positionId = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double pnl = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                 + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                 + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      // The CLOSING deal's own type is the inverse of the position's
      // direction (selling closes a BUY) -- report the position's original
      // direction, which is what a human (or the override engine) expects
      // "order_type" to mean here.
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      string orderType = (dealType == DEAL_TYPE_SELL) ? "BUY" : "SELL";

      string entry = StringFormat(
         "{\"ticket\":\"%I64d\",\"symbol\":\"%s\",\"order_type\":\"%s\",\"volume\":%.2f,"
         "\"profit\":%.2f,\"magic_number\":%d,\"closed_at\":%d}",
         positionId, target.symbol, orderType, HistoryDealGetDouble(dealTicket, DEAL_VOLUME),
         pnl, (int)HistoryDealGetInteger(dealTicket, DEAL_MAGIC),
         (long)HistoryDealGetInteger(dealTicket, DEAL_TIME));

      ArrayResize(entries, count + 1);
      entries[count] = entry;
      count++;
     }

   string json = "[";
   for(int i = 0; i < count; i++)
     {
      if(i > 0)
         json += ",";
      json += entries[i];
     }
   json += "]";

   WriteJsonFile(target.closedHistoryPath, json);
  }

//--- write a CSV line each time a new bar closes, checked on THIS       --
//--- chart's tick cadence but against the TARGET's own timeframe --------
void ExportNewBarIfClosed(SymbolTarget &target)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   // shift 0 = current forming bar, shift 1 = the bar that just closed.
   if(CopyRates(target.symbol, target.timeframe, 0, 2, rates) < 2)
      return;

   datetime currentBarTime = rates[0].time;
   if(currentBarTime == target.lastBarTime)
      return;

   // NOTE: must be FILE_CSV, not FILE_TXT -- FileWrite() only inserts a
   // delimiter between its arguments when the file is opened as CSV. With
   // FILE_TXT each value gets stringified and concatenated with no
   // separator at all (e.g. "17901757201.141121.14118..."), which the
   // vps_agent side can't parse as CSV. FILE_CSV defaults to a comma
   // delimiter, matching _parse_ohlc_line()'s csv.reader on the Python side.
   int handle = FileOpen(target.ohlcPath, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      Print("Failed to open OHLC export file for ", target.symbol, " ", target.tfLabel, ": ", GetLastError());
      return;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, (long)rates[1].time, rates[1].open, rates[1].high, rates[1].low, rates[1].close,
             (double)rates[1].tick_volume);
   FileClose(handle);

   target.lastBarTime = currentBarTime;
  }

//--- read new lines from the command file, execute them, write results --
void ProcessPendingCommands(SymbolTarget &target)
  {
   if(!FileIsExist(target.commandPath, FILE_COMMON))
      return;

   // Don't even read pending commands while genuinely disconnected from the
   // trade server (e.g. right at weekend market reopen, or a network blip)
   // -- OrderSend would just burn through MaxRetries and write a permanent
   // ERROR result, causing the brain to treat a perfectly good signal as
   // rejected. Leaving commandReadOffset untouched means these lines get
   // picked up and retried on a later tick once connectivity is back,
   // instead of being lost.
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      return;

   int handle = FileOpen(target.commandPath, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle, target.commandReadOffset, SEEK_SET);

   bool advanced = false;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) == 0)
         continue;
      ExecuteCommandLine(line, target.symbol, target.resultPath, target);
      advanced = true;
     }
   target.commandReadOffset = (int)FileTell(handle);
   FileClose(handle);
   if(advanced)
      SaveCommandOffset(target);  // persist so a restart resumes here, not from 0 (see LoadCommandOffset)
  }

//--- extremely small JSON field reader (fine for a flat, known schema) --
string JsonField(string json, string key)
  {
   string needle = "\"" + key + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0)
      return "";
   int start = pos + StringLen(needle);
   int len = StringLen(json);
   // skip whitespace/quote
   while(start < len && (StringGetCharacter(json, start) == ' ' || StringGetCharacter(json, start) == '\"'))
      start++;
   int end = start;
   while(end < len)
     {
      int ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}' || ch == '\"')
         break;
      end++;
     }
   return StringSubstr(json, start, end - start);
  }

//--- a stable small int from a strategy_id string, for the request's magic
//--- number -- lets you tell strategies apart in the terminal/history ----
int MagicFromStrategyId(string strategyId)
  {
   if(StringLen(strategyId) == 0)
      return 0;
   int hash = 0;
   for(int i = 0; i < StringLen(strategyId); i++)
      hash = (hash * 31 + StringGetCharacter(strategyId, i)) % 1000000;
   return hash;
  }

//--- NETTING accounts merge every position on a symbol into ONE, so a --------
//--- second strategy opening the same symbol under a different magic ------
//--- number would be folded into (and later closed with) the first's. ------
//--- Refuse instead: the brain's per-strategy magic numbers only isolate ----
//--- strategies on a HEDGING account. ----------------------------------------
bool NettingConflict(string sym, int newMagic, string &why)
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      return false;
   if(!PositionSelect(sym))
      return false;
   long existingMagic = PositionGetInteger(POSITION_MAGIC);
   if(existingMagic == (long)newMagic)
      return false;
   why = "netting account: " + sym + " already has a position under magic " + IntegerToString(existingMagic) +
         "; opening under magic " + IntegerToString(newMagic) + " would merge with it -- refusing " +
         "(use a hedging account to run several strategies on one symbol)";
   return true;
  }

//--- Snaps a requested lot to what the broker will actually accept for  --
//--- this symbol (SYMBOL_VOLUME_MIN/MAX/STEP). Without this a martingale --
//--- lot that grows past the broker's max, or lands off the step grid,   --
//--- is rejected by OrderSend (retcode 10014 "invalid volume") on every  --
//--- retry and the signal is lost. Rounds DOWN to the step so it never   --
//--- exceeds what was asked for; `note` says what changed. ---------------
double NormalizeOrderVolume(string symbol, double requested, string &note)
  {
   double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(vmin <= 0.0)
      vmin = 0.01;
   if(vstep <= 0.0)
      vstep = vmin;
   double v = requested;
   if(vmax > 0.0 && v > vmax)
      v = vmax;
   v = MathFloor(v / vstep + 1e-9) * vstep;
   if(v < vmin)
      v = vmin;
   int digits = (int)MathMax(0.0, MathCeil(-MathLog10(vstep) - 1e-9));
   v = NormalizeDouble(v, digits);
   if(MathAbs(v - requested) > 1e-9)
      note = "volume adjusted " + DoubleToString(requested, 4) + " -> " + DoubleToString(v, digits) +
             " (broker min " + DoubleToString(vmin, digits) + ", max " + DoubleToString(vmax, digits) +
             ", step " + DoubleToString(vstep, digits) + ")";
   return v;
  }

//--- Shrinks a lot so its required margin fits in 90% of the free margin --
//--- (a martingale lot after a losing streak is exactly when free margin --
//--- is lowest). Returns the input unchanged if margin can't be computed. -
double FitVolumeToFreeMargin(string symbol, ENUM_ORDER_TYPE type, double volume, double price)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(type, symbol, volume, price, margin) || margin <= 0.0)
      return volume;
   double budget = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.90;
   if(margin <= budget)
      return volume;
   return volume * (budget / margin);
  }

//--- picks a filling mode the symbol actually supports. Unlike MT4,      --
//--- OrderSend here fails outright (retcode 10030 / "unsupported         --
//--- filling mode") if you guess wrong, so this is checked at runtime    --
//--- rather than hardcoded to one mode. ----------------------------------
ENUM_ORDER_TYPE_FILLING PickFillingMode(string symbol)
  {
   long filling = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//--- sums DEAL_PROFIT + DEAL_SWAP + DEAL_COMMISSION across every deal    --
//--- (open AND close) belonging to one position id -- the MT5 equivalent --
//--- of MT4's single-ticket OrderProfit()+OrderSwap()+OrderCommission(). --
//--- Returns false if no deals could be found (caller should fall back  --
//--- to the pre-close floating profit+swap in that case). ----------------
bool GetRealizedPositionPnl(ulong positionId, double &pnlOut)
  {
   pnlOut = 0.0;
   if(!HistorySelectByPosition(positionId))
      return false;
   int total = HistoryDealsTotal();
   if(total == 0)
      return false;
   for(int i = 0; i < total; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;
      pnlOut += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      pnlOut += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      pnlOut += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
     }
   return true;
  }

//--- pulls a batch of historical closed candles in one shot (CopyRates
//--- can return thousands at once) and overwrites target.historyPath
//--- with all of them -- vps_agent's FileTailer detects the overwrite
//--- (its prefix-hash rewrite check) and forwards the whole batch to the
//--- relay as one ohlc_batch message, instead of the live export's
//--- one-new-bar-per-close trickle. Triggered by a BACKFILL_HISTORY
//--- command (see ExecuteCommandLine) written by vps_agent in response
//--- to the relay's POST /admin/backfill.
void ExecuteBackfillHistory(SymbolTarget &target, string line)
  {
   if(!InpUseAsCandleHistory)
     {
      Print("Backfill request for ", target.symbol, " ", target.tfLabel, " IGNORED: input InpUseAsCandleHistory is false on this terminal, "
            "so it does not supply candle history. Request the backfill from a terminal that has it set to true.");
      return;
     }
   string barsStr = JsonField(line, "bars");
   int requested = (StringLen(barsStr) > 0) ? (int)StringToInteger(barsStr) : 5000;
   if(requested <= 0)
      requested = 3000;
   if(requested > 50000)
      requested = 50000;  // matches the relay's own /admin/backfill cap

   MqlRates rates[];
   ArraySetAsSeries(rates, false);  // ascending time order -- oldest bar first
   int copied = CopyRates(target.symbol, target.timeframe, 0, requested, rates);
   if(copied <= 0)
     {
      Print("Backfill request for ", target.symbol, " ", target.tfLabel, ": CopyRates returned 0 bars "
            "(requested ", requested, ") -- the terminal may not have that much history downloaded yet. "
            "Try Tools > Options > Charts > \"Max bars in history\", or scroll the chart back to force MT5 "
            "to fetch more from the broker, then retry.");
      return;
     }

   // Same FILE_CSV fix as ExportNewBarIfClosed() above -- FILE_TXT was
   // writing every row with no delimiters between the fields.
   int handle = FileOpen(target.historyPath, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      Print("Failed to open history backfill export file for ", target.symbol, " ", target.tfLabel, ": ",
            GetLastError());
      return;
     }
   for(int i = 0; i < copied; i++)
      FileWrite(handle, (long)rates[i].time, rates[i].open, rates[i].high, rates[i].low, rates[i].close,
                (double)rates[i].tick_volume);
   FileClose(handle);

   Print("Backfill complete for ", target.symbol, " ", target.tfLabel, ": wrote ", copied,
         " of ", requested, " requested bars to ", target.historyPath);
  }

//--- Turns the command's stop_loss/take_profit into the absolute prices OrderSend needs.   --
//--- Pip size for a symbol: 10 points on 3/5-digit symbols, otherwise 1 point (same definition as ResolveStops). --
double PipSize(string symbol)
  {
   int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (digits == 3 || digits == 5) ? point * 10.0 : point;
  }

//--- Live spread in pips from a FRESH tick (not the ~10 s old market_status file). -1 when unknown. ---------------
double LiveSpreadPips(string symbol)
  {
   MqlTick t;
   double pip = PipSize(symbol);
   if(pip <= 0.0 || !SymbolInfoTick(symbol, t))
      return -1.0;
   return (t.ask - t.bid) / pip;
  }

//--- Fill reporting (OPEN acks): the price actually obtained, and the adverse slippage in pips. -----------------
//--- Order of trust: the OrderSend result's own price, then the deal in history, then the position's open price. --
//--- Returns 0 when none of them can be read (the ack then simply carries no fill_price / slippage_pips).       --
double ResolveFillPrice(double resultPrice, ulong dealTicket, ulong positionTicket)
  {
   if(resultPrice > 0.0)
      return resultPrice;
   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
     {
      double dp = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      if(dp > 0.0)
         return dp;
     }
   if(positionTicket > 0 && PositionSelectByTicket(positionTicket))
      return PositionGetDouble(POSITION_PRICE_OPEN);
   return 0.0;
  }

//--- Positive = the fill was WORSE than requested (BUY paid more / SELL received less); negative = price improvement. --
double AdverseSlippagePips(string symbol, ENUM_ORDER_TYPE type, double requested, double filled)
  {
   double pip = PipSize(symbol);
   if(pip <= 0.0 || requested <= 0.0 || filled <= 0.0)
      return 0.0;
   return (type == ORDER_TYPE_BUY) ? (filled - requested) / pip : (requested - filled) / pip;
  }

//--- OPEN-only spread guard. maxPips<=0 -> off. action "reject": refuse at once. action "wait": re-check every   --
//--- ~250 ms for up to waitSeconds, then refuse. Fills `note` with a clear reason when it returns false.        --
bool SpreadAllowsOpen(string symbol, double maxPips, string action, double waitSeconds, string &note)
  {
   if(maxPips <= 0.0)
      return true;
   uint deadline = GetTickCount() + (uint)(MathMax(0.0, waitSeconds) * 1000.0);
   while(true)
     {
      double sp = LiveSpreadPips(symbol);
      if(sp >= 0.0 && sp <= maxPips)
         return true;
      if(sp < 0.0)
        {
         note = "spread unknown for " + symbol + " (no tick) -- OPEN refused by the spread guard";
         if(action != "wait" || GetTickCount() >= deadline)
            return false;
        }
      else
        {
         note = "spread " + DoubleToString(sp, 1) + " pips > max " + DoubleToString(maxPips, 1) + " pips (" + symbol + ")";
         if(action != "wait" || GetTickCount() >= deadline)
            return false;
        }
      Sleep(250);
     }
   return false;
  }

//--- unit "price" (default; what the brain sends): value is already an absolute price.     --
//--- unit "pips": value is a DISTANCE from the fill price (SL below/TP above for a BUY,    --
//--- reversed for a SELL) -- the only form of override that is valid for both directions.  --
//--- A pip is 10 points on 3/5-digit symbols, otherwise 1 point. Distances closer than the --
//--- broker's minimum stop level are widened to it. Returns false (+ note) when the stop   --
//--- would sit on the wrong side of the price: the order is then REFUSED rather than sent  --
//--- without the protection the operator asked for (OrderSend would reject it anyway).     --
bool ResolveStops(string symbol, ENUM_ORDER_TYPE type, double price,
                  double slValue, string slUnit, double tpValue, string tpUnit,
                  double &slOut, double &tpOut, string &note)
  {
   slOut = 0.0;
   tpOut = 0.0;
   int    digits  = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double pip     = (digits == 3 || digits == 5) ? point * 10.0 : point;
   double minDist = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   bool   isBuy   = (type == ORDER_TYPE_BUY);

   if(slValue > 0.0)
     {
      double px = slValue;
      if(slUnit == "pips")
        {
         double dist = MathMax(slValue * pip, minDist);
         px = isBuy ? price - dist : price + dist;
        }
      px = NormalizeDouble(px, digits);
      if((isBuy && px >= price) || (!isBuy && px <= price))
        {
         note = "stop_loss " + DoubleToString(px, digits) + " is on the wrong side of price " + DoubleToString(price, digits) +
                " for a " + (isBuy ? "BUY" : "SELL") + " -- order refused instead of opening unprotected";
         return false;
        }
      slOut = px;
     }
   if(tpValue > 0.0)
     {
      double px = tpValue;
      if(tpUnit == "pips")
        {
         double dist = MathMax(tpValue * pip, minDist);
         px = isBuy ? price + dist : price - dist;
        }
      px = NormalizeDouble(px, digits);
      if((isBuy && px <= price) || (!isBuy && px >= price))
        {
         note = "take_profit " + DoubleToString(px, digits) + " is on the wrong side of price " + DoubleToString(price, digits) +
                " for a " + (isBuy ? "BUY" : "SELL") + " -- order refused";
         return false;
        }
      tpOut = px;
     }
   return true;
  }

void ExecuteCommandLine(string line, string targetSymbol, string resultPath, SymbolTarget &target)
  {
   string signalId  = JsonField(line, "signal_id");
   string action     = JsonField(line, "action");
   string direction  = JsonField(line, "direction");
   string volumeStr  = JsonField(line, "volume");
   string ticketStr  = JsonField(line, "ticket");
   string strategyId = JsonField(line, "strategy_id");
   string cmdSymbol  = JsonField(line, "symbol");
   string magicStr   = JsonField(line, "magic_number");
   string slStr      = JsonField(line, "stop_loss");
   string tpStr      = JsonField(line, "take_profit");
   string cmdComment = JsonField(line, "comment");
   string slUnit     = JsonField(line, "sl_unit");   // "price" (default) | "pips" -- see ResolveStops
   string tpUnit     = JsonField(line, "tp_unit");
   // Spread / slippage guard (OPEN only). Keys are absent unless the dashboard policy sets them -- an older agent
   // simply never sends them and the EA inputs (InpMaxSpreadPips, Slippage) apply.
   string maxSpreadStr = JsonField(line, "max_spread_pips");
   string maxSlipStr   = JsonField(line, "max_slippage_pips");
   string spreadAction = JsonField(line, "spread_action");
   string spreadWaitStr = JsonField(line, "spread_wait_seconds");
   double maxSpreadPips = (StringLen(maxSpreadStr) > 0 && maxSpreadStr != "null") ? StringToDouble(maxSpreadStr) : InpMaxSpreadPips;
   double maxSlipPips   = (StringLen(maxSlipStr) > 0 && maxSlipStr != "null") ? StringToDouble(maxSlipStr) : 0.0;
   double spreadWaitSec = (StringLen(spreadWaitStr) > 0 && spreadWaitStr != "null") ? StringToDouble(spreadWaitStr) : 0.0;
   double volume     = (StringLen(volumeStr) > 0) ? StringToDouble(volumeStr) : DefaultLots;
   // "null"/empty both mean "no override was sent" -- 0.0 is the correct
   // fallback for both (OrderSend interprets sl/tp==0 as "no stop"), so
   // unlike magic_number there's no need to distinguish them further here.
   double stopLoss   = (StringLen(slStr) > 0 && slStr != "null") ? StringToDouble(slStr) : 0.0;
   double takeProfit  = (StringLen(tpStr) > 0 && tpStr != "null") ? StringToDouble(tpStr) : 0.0;
   // "magic_number" is only ever present (as a real number, not JSON null) when a
   // Parameter Route Assignment pinned this exact target to a specific parameter
   // set -- see multi_agent_brain/agents/route_assignment_agent.py and
   // schemas.Signal.magic_number. JsonField returns the literal text "null" for a
   // JSON null, not an empty string, so that has to be checked explicitly rather
   // than just "non-empty" -- otherwise every ordinary (unassigned) OPEN would
   // silently trade under magic number 0 instead of falling back correctly.
   int magic = (StringLen(magicStr) > 0 && magicStr != "null")
               ? (int)StringToInteger(magicStr)
               : MagicFromStrategyId(strategyId);

   if(action == "OPEN")
      RememberMagic(target, magic);  // so this target's own orders/closed-history exports (see
                                      // ExportOrdersStatus) include it right away, no restart needed

   if(StringLen(cmdSymbol) > 0 && cmdSymbol != targetSymbol)
      Print("WARNING: command's own \"symbol\" field (", cmdSymbol, ") does not match the symbol this "
            "command file is scoped to (", targetSymbol, "). Trading ", targetSymbol, " anyway -- the file "
            "a command arrived on, not the embedded field, is what determines which symbol vps_agent/the "
            "relay/the brain believe this signal targets.");

   int status = -1;
   string detail = "";
   string resultTicket = "";
   string resultPnl = "";
   // Execution quality, reported in the OPEN ack (empty = not known / not applicable). See WriteResult.
   string ackReqPrice = "", ackFillPrice = "", ackSlipPips = "", ackSpreadPips = "";

   if(action == "BACKFILL_HISTORY")
     {
      ExecuteBackfillHistory(target, line);
      return;  // no OPEN/CLOSE result to write -- see ExecuteBackfillHistory's own Print() logging
     }

   if(action == "OPEN" && NettingConflict(targetSymbol, magic, detail))
     {
      status = 0;
     }
   else if(action == "OPEN")
     {
      ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      ulong ticket = 0;
      uint lastRetcode = 0;
      string stopError = "";
      // Spread guard BEFORE anything is sized or sent: refusing here costs nothing; OrderSend in a news spike does.
      string spreadNote = "";
      if(!SpreadAllowsOpen(targetSymbol, maxSpreadPips, spreadAction, spreadWaitSec, spreadNote))
         stopError = spreadNote;
      // Spread seen at the decision, reported even when the guard refused (that is what the limit saved you from).
      double decisionSpread = LiveSpreadPips(targetSymbol);
      if(decisionSpread >= 0.0)
         ackSpreadPips = DoubleToString(decisionSpread, 2);
      int    priceDigits = (int)SymbolInfoInteger(targetSymbol, SYMBOL_DIGITS);
      ulong  filledDeal = 0;
      double filledResultPrice = 0.0;
      double sentPrice = 0.0;
      // Make the lot something the broker will accept and the account can afford BEFORE trying.
      string volNote = "";
      MqlTick volTick;
      if(SymbolInfoTick(targetSymbol, volTick))
        {
         double fitted = FitVolumeToFreeMargin(targetSymbol, orderType, volume,
                                               (orderType == ORDER_TYPE_BUY) ? volTick.ask : volTick.bid);
         if(fitted < volume)
            volNote = "reduced to fit free margin; ";
         volume = fitted;
        }
      string normNote = "";
      volume = NormalizeOrderVolume(targetSymbol, volume, normNote);
      volNote += normNote;
      if(StringLen(volNote) > 0)
         Print("Volume for ", targetSymbol, ": ", volNote);
      // Retry a few times with a fresh tick each attempt -- a requote or a
      // momentary connectivity blip shouldn't silently drop a signal.
      for(int attempt = 1; attempt <= MaxRetries && StringLen(stopError) == 0; attempt++)
        {
         MqlTick tick;
         if(!SymbolInfoTick(targetSymbol, tick))
           {
            lastRetcode = 0;
            Print("SymbolInfoTick failed on attempt ", attempt, "/", MaxRetries, " -- retrying");
            Sleep(RetryDelayMs);
            continue;
           }
         double price = (orderType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
         // The price this attempt asks for, and the spread on that very tick (a retry replaces both).
         sentPrice = price;
         ackReqPrice = DoubleToString(price, priceDigits);
         if(PipSize(targetSymbol) > 0.0)
            ackSpreadPips = DoubleToString((tick.ask - tick.bid) / PipSize(targetSymbol), 2);

         MqlTradeRequest request;
         MqlTradeResult  result;
         ZeroMemory(request);
         ZeroMemory(result);
         request.action       = TRADE_ACTION_DEAL;
         request.symbol       = targetSymbol;
         request.volume       = volume;
         request.type         = orderType;
         request.price        = price;
         request.deviation    = (maxSlipPips > 0.0) ? (ulong)MathMax(1.0, MathRound(maxSlipPips * (PipSize(targetSymbol) / SymbolInfoDouble(targetSymbol, SYMBOL_POINT)))) : (ulong)Slippage;
         request.magic        = magic;
         request.comment      = (StringLen(cmdComment) > 0 && cmdComment != "null") ? cmdComment : "agentic-signal";
         request.type_filling = PickFillingMode(targetSymbol);
         request.type_time    = ORDER_TIME_GTC;
         // Stops: see ResolveStops -- "pips" distances are widened to the broker's minimum stop
         // level; an absolute price on the wrong side of the fill price refuses the order.
         double slPrice = 0.0, tpPrice = 0.0;
         string stopNote = "";
         if(!ResolveStops(targetSymbol, orderType, price, stopLoss, slUnit, takeProfit, tpUnit, slPrice, tpPrice, stopNote))
           {
            stopError = stopNote;   // retrying cannot fix a stop on the wrong side -- refuse now
            break;
           }
         if(slPrice > 0.0)
            request.sl = slPrice;
         if(tpPrice > 0.0)
            request.tp = tpPrice;

         if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
           {
            ticket = result.order;
            filledDeal = result.deal;
            filledResultPrice = result.price;
            break;
           }
         lastRetcode = result.retcode;
         Print("OrderSend attempt ", attempt, "/", MaxRetries, " failed: retcode=", result.retcode,
               " (", result.comment, ") -- retrying");
         Sleep(RetryDelayMs);
        }
      if(ticket > 0)
        {
         status = 1;
         resultTicket = IntegerToString((long)ticket);
         detail = volNote;   // empty unless the lot had to be adjusted -- then the ack says how
         double filled = ResolveFillPrice(filledResultPrice, filledDeal, ticket);
         if(filled > 0.0)
           {
            ackFillPrice = DoubleToString(filled, priceDigits);
            ackSlipPips  = DoubleToString(AdverseSlippagePips(targetSymbol, orderType, sentPrice, filled), 2);
           }
        }
      else
        {
         status = 0;
         if(StringLen(stopError) > 0)
            detail = stopError;
         else
            detail = "OrderSend failed after " + IntegerToString(MaxRetries) + " attempt(s): retcode=" +
                      IntegerToString((int)lastRetcode) + " volume=" + DoubleToString(volume, 2) +
                      (StringLen(volNote) > 0 ? " (" + volNote + ")" : "");
        }
     }
   else if(action == "CLOSE")
     {
      // A ticket MUST be provided -- the brain tracks exactly which position
      // belongs to which strategy/parameter version (see Position table in
      // multi_agent_brain/db/models.py) and sends that specific ticket.
      // "close whatever is open on this symbol" is not safe once more than
      // one strategy/signal can have a position open on the same symbol --
      // and on a NETTING account it may not even be possible to isolate
      // (see the header comment on hedging vs netting).
      if(StringLen(ticketStr) == 0)
        {
         status = 0;
         detail = "no ticket provided for CLOSE -- refusing to guess which position to close";
        }
      else
        {
         ulong targetTicket = (ulong)StringToInteger(ticketStr);
         bool closed = false;
         double pnlBeforeClose = 0;
         ulong positionId = 0;
         uint lastRetcode = 0;
         for(int attempt = 1; attempt <= MaxRetries; attempt++)
           {
            if(!PositionSelectByTicket(targetTicket))
              {
               detail = "ticket " + ticketStr + " not found (already closed, or wrong terminal)";
               break;
              }
            // The brain echoes the magic the position was opened under. If it
            // doesn't match, this ticket is not the position the brain thinks it
            // is (another strategy's, or a reused ticket) -- never close it.
            // magic_number is absent/null for positions opened before the brain
            // recorded magic numbers; those skip the check.
            if(StringLen(magicStr) > 0 && magicStr != "null" &&
               PositionGetInteger(POSITION_MAGIC) != (long)StringToInteger(magicStr))
              {
               detail = "ticket " + ticketStr + " has magic " + IntegerToString((long)PositionGetInteger(POSITION_MAGIC)) +
                        " but the command expected " + magicStr + " -- refusing to close another strategy's position";
               break;
              }
            pnlBeforeClose = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            positionId = PositionGetInteger(POSITION_IDENTIFIER);
            string posSymbol = PositionGetString(POSITION_SYMBOL);  // authoritative -- trust the position, not the command file
            double posVolume = PositionGetDouble(POSITION_VOLUME);
            long posType = PositionGetInteger(POSITION_TYPE);
            ENUM_ORDER_TYPE closeType = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

            MqlTick tick;
            if(!SymbolInfoTick(posSymbol, tick))
              {
               Print("SymbolInfoTick failed on close attempt ", attempt, "/", MaxRetries, " -- retrying");
               Sleep(RetryDelayMs);
               continue;
              }
            double closePrice = (closeType == ORDER_TYPE_SELL) ? tick.bid : tick.ask;

            MqlTradeRequest request;
            MqlTradeResult  result;
            ZeroMemory(request);
            ZeroMemory(result);
            request.action       = TRADE_ACTION_DEAL;
            request.position     = targetTicket;
            request.symbol       = posSymbol;
            request.volume       = posVolume;
            request.type         = closeType;
            request.price        = closePrice;
            request.deviation    = Slippage;
            request.magic        = (int)PositionGetInteger(POSITION_MAGIC);
            request.comment      = (StringLen(cmdComment) > 0 && cmdComment != "null") ? cmdComment : "agentic-signal-close";
            request.type_filling = PickFillingMode(posSymbol);
            request.type_time    = ORDER_TIME_GTC;

            if(OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE)
              {
               closed = true;
               break;
              }
            lastRetcode = result.retcode;
            Print("OrderSend (close) attempt ", attempt, "/", MaxRetries, " failed: retcode=", result.retcode,
                  " (", result.comment, ") -- retrying");
            Sleep(RetryDelayMs);
           }
         if(closed)
           {
            status = 1;
            resultTicket = IntegerToString((long)targetTicket);
            double realizedPnl = 0.0;
            if(GetRealizedPositionPnl(positionId, realizedPnl))
               resultPnl = DoubleToString(realizedPnl, 2);
            else
              {
               Print("WARNING: could not read deal history for position ", positionId, " right after closing "
                     "ticket ", ticketStr, " -- reporting pre-close profit+swap WITHOUT commission instead. "
                     "Check the terminal's history tab if this figure looks off.");
               resultPnl = DoubleToString(pnlBeforeClose, 2);
              }
           }
         else
           {
            status = 0;
            if(StringLen(detail) == 0)
               detail = "OrderSend (close) failed after " + IntegerToString(MaxRetries) + " attempt(s): retcode=" +
                         IntegerToString((int)lastRetcode);
           }
        }
     }

   WriteResult(resultPath, signalId, status == 1 ? "EXECUTED" : "ERROR", detail, resultTicket, resultPnl,
               ackReqPrice, ackFillPrice, ackSlipPips, ackSpreadPips);
  }

//--- One JSON line per result. req_price / fill_price / slippage_pips / spread_pips are appended ONLY when known, --
//--- so CLOSE results and older flows are byte-for-byte what they were. slippage_pips > 0 = filled worse.         --
void WriteResult(string resultPath, string signalId, string statusStr, string detail, string ticket = "", string pnl = "",
                 string reqPrice = "", string fillPrice = "", string slipPips = "", string spreadPips = "")
  {
   int handle = FileOpen(resultPath, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   string json = "{\"signal_id\":\"" + signalId + "\",\"status\":\"" + statusStr + "\"," +
                 "\"detail\":\"" + detail + "\"," +
                 "\"ticket\":\"" + ticket + "\"," +
                 "\"pnl\":\"" + pnl + "\"";
   if(StringLen(reqPrice) > 0)
      json += ",\"req_price\":\"" + reqPrice + "\"";
   if(StringLen(fillPrice) > 0)
      json += ",\"fill_price\":\"" + fillPrice + "\"";
   if(StringLen(slipPips) > 0)
      json += ",\"slippage_pips\":\"" + slipPips + "\"";
   if(StringLen(spreadPips) > 0)
      json += ",\"spread_pips\":\"" + spreadPips + "\"";
   json += "}";
   FileWrite(handle, json);
   FileClose(handle);
  }
//+------------------------------------------------------------------+
