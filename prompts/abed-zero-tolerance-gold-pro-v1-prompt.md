# Prompt: Abed Zero Tolerance Gold PRO v1

Create a professional TradingView Pine Script v5 indicator for XAUUSD / Gold and Forex.

Indicator name:
`Abed Zero Tolerance Gold PRO v1 - Clean Core`

Use `indicator()`, not `strategy()`.

Declaration must include:
- `overlay=true`
- `max_labels_count=500`
- `max_lines_count=500`
- `max_boxes_count=150`
- `max_bars_back=500`

Main goal:
Build a clean, practical, non-repainting smart entry indicator that gives strong BUY/SELL signals based on candle structure, support/resistance, liquidity sweeps, break of structure, retest logic, multi-timeframe trend, macro risk filter, and manual news-risk mode.

Critical rules:
1. Pine Script v5 only.
2. Use `indicator()`, not `strategy()`.
3. No `strategy.entry` and no `study()`.
4. No `lookahead_on`.
5. Every `request.security()` must use `lookahead=barmerge.lookahead_off`.
6. BUY confirmation must never appear on a red candle.
7. SELL confirmation must never appear on a green candle.
8. Confirmed entry must never appear before a WAIT setup.
9. Labels must be anchored to the actual candle high/low using price y-location, not floating away from the candle.
10. Trade plan updates only after confirmed entry.
11. Performance statistics use only confirmed entry signals.
12. Dashboard must be controllable and movable.
13. All major modules need ON/OFF controls.
14. Alerts must exist for WAIT and CONFIRMED signals.

The chart must show only these four signal labels:
- WAIT BUY
- WAIT SELL
- BUY CONFIRMED
- SELL CONFIRMED

No other buy/sell labels are allowed.

Logic layers:
1. Trend filter:
   - EMA 50/200 on current timeframe.
   - HTF confirmation from 15M, 1H, and 4H.
   - Optional strict mode requiring HTF alignment.

2. Candle strength:
   - Body percent of full candle range.
   - Close location percent.
   - Wick rejection.
   - Bullish candle required for BUY confirmation.
   - Bearish candle required for SELL confirmation.

3. Support and resistance:
   - Pivot-based support/resistance.
   - Previous day high/low.
   - Previous week high/low.
   - ATR-based zone proximity.

4. Liquidity sweep:
   - Buy sweep: price breaks below support then closes back above it.
   - Sell sweep: price breaks above resistance then closes back below it.

5. Market structure:
   - Break of recent high/low.
   - Optional structure confirmation.

6. Sideways filter:
   - Block entries when ATR/range is too low or EMA distance is too tight.

7. News/macro filter:
   - Manual mode: Normal / High News Risk / No Trade.
   - Optional DXY and US10Y risk filter.

8. Trade plan:
   - Entry at confirmation close.
   - SL by ATR or latest swing.
   - TP1, TP2, TP3 using ATR/Fixed/Hybrid mode.
   - Optional big target around 20 XAU price points when trend is strong.

9. Performance dashboard:
   - Mode
   - News Risk
   - Trend Current / 15M / 1H / 4H
   - Zone status
   - Candle status
   - Signal quality percent
   - Active trade direction
   - Entry / SL / TP1 / TP2 / TP3
   - Total trades
   - Wins
   - Losses
   - Win rate
   - Protected trades
   - Net points
   - Real expected R:R

Build the first version as a clean, stable core. Avoid heavy visual clutter. Keep signals readable on 1M and 5M charts.