# ABED XAUUSD TV EXECUTOR PRO v1.0

Phase 1 is intentionally small and safe.

## What it does

- Reads `ABED_TV_SIGNAL.json` from MT5 Common Files folder.
- Validates secret, symbol, spread, daily limits, open-trade limit, and duplicate alert ID.
- Executes BUY / SELL market orders with SL and TP.
- Supports CLOSE_ALL / CLOSE_BUY / CLOSE_SELL.
- Writes logs to `ABED_TV_EXECUTOR_LOG.csv`.

## Install

1. Open MT5.
2. Go to `File > Open Data Folder`.
3. Go to `MQL5 > Experts`.
4. Copy `ABED_XAUUSD_TV_EXECUTOR_PRO_v1_0.mq5`.
5. Open MetaEditor and compile.
6. Attach EA to XAUUSD / GOLD chart.
7. Enable Algo Trading.
8. Keep `InpUseCommonFilesFolder = true`.

## Test

Create this file in MT5 Common Files folder:

`File > Open Data Folder > go up to Terminal\Common\Files`

File name:

`ABED_TV_SIGNAL.json`

Example BUY:

```json
{
  "secret": "ABED_SECRET_2026",
  "strategy": "CLEAN_LABELS_v6",
  "symbol": "XAUUSD",
  "timeframe": "5M",
  "action": "BUY",
  "alert_id": "TEST_BUY_001",
  "sl": 3334.20,
  "tp1": 3347.00,
  "tp2": 3354.00,
  "reason": "MANUAL_TEST_BUY"
}
```

To send a new test, change `alert_id`, for example `TEST_BUY_002`.

## Phase 1 limits

No TP1 partial close, no breakeven, no trailing. Those are Phase 1.1 after basic execution is confirmed stable.
