"""Real screening/analysis engine.

Fetches OHLCV via yfinance, computes indicators, and derives the app's signal /
score / category taxonomy. Every public entry point falls back to the
deterministic mock generators (``mock_data``) if data fetch or computation
fails, so the API never hard-fails on a flaky data source.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Callable, List, Optional

import pandas as pd

from . import indicators, mock_data
from .cache import make_cached_fetcher
from .universe import UniverseRepository
from .models import (
    AnalysisResult,
    Market,
    ScreenerCategory,
    ScreenerMatch,
    ScreenerResult,
    WeeklyPrediction,
)

logger = logging.getLogger("tradewiz.engine")

# yfinance ticker suffix per market.
MARKET_SUFFIX = {
    Market.IDX: ".JK",
    Market.HKEX: ".HK",
    Market.KOSPI: ".KS",
    Market.KOSDAQ: ".KQ",
}


def yf_symbol(symbol: str, market: Market) -> str:
    """Map a bare symbol + market to a yfinance ticker (idempotent)."""
    sym = symbol.upper().strip()
    suffix = MARKET_SUFFIX[market]
    return sym if sym.endswith(suffix) else f"{sym}{suffix}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# A fetcher returns an OHLCV DataFrame (columns: Open/High/Low/Close/Volume) or
# raises. Signature: (ticker, period, interval). Injectable so tests can supply
# synthetic data with no network.
Fetcher = Callable[[str, str, str], pd.DataFrame]


def _yf_fetch(ticker: str, period: str = "1y", interval: str = "1d") -> pd.DataFrame:
    import yfinance as yf

    df = yf.download(
        ticker,
        period=period,
        interval=interval,
        auto_adjust=False,
        progress=False,
        threads=False,
    )
    if df is None or df.empty:
        raise ValueError(f"No data for {ticker}")
    # yfinance may return a column MultiIndex for a single ticker; flatten it.
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    needed = {"Open", "High", "Low", "Close", "Volume"}
    if not needed.issubset(set(df.columns)):
        raise ValueError(f"Missing OHLCV columns for {ticker}: {df.columns}")
    return df


class AnalysisEngine:
    def __init__(
        self,
        fetcher: Optional[Fetcher] = None,
        universe: Optional[UniverseRepository] = None,
    ):
        # Default: yfinance behind the on-disk OHLCV cache (TTL via env).
        self._fetch = fetcher or make_cached_fetcher(_yf_fetch)
        self._universe = universe or UniverseRepository()

    # -- categories --------------------------------------------------------

    def categorize(self, ind: dict) -> List[ScreenerCategory]:
        """Map indicator values onto the app's category taxonomy."""
        cats: List[ScreenerCategory] = []
        close = ind.get("close")
        rsi = ind.get("rsi")
        ema20 = ind.get("ema20")
        ema50 = ind.get("ema50")
        sma200 = ind.get("sma200")
        macd_hist = ind.get("macd_hist")
        macd_hist_prev = ind.get("macd_hist_prev")
        vr = ind.get("volume_ratio")
        atr_pct = ind.get("atr_pct")

        def gt(a, b) -> bool:
            return a is not None and b is not None and a > b

        # Trend: EMA20 > EMA50 (and price above) => bullish; inverse => bearish.
        if gt(ema20, ema50) and gt(close, ema20):
            cats.append(ScreenerCategory.bullish)
        if gt(ema50, ema20) and gt(ema20, close):
            cats.append(ScreenerCategory.bearish)

        # Scalping: elevated short-term volatility.
        if atr_pct is not None and atr_pct >= 4.0:
            cats.append(ScreenerCategory.scalping)

        # Accumulation: MACD histogram turning up while volume rises.
        if (
            macd_hist is not None
            and macd_hist_prev is not None
            and macd_hist > macd_hist_prev
            and vr is not None
            and vr >= 1.2
        ):
            cats.append(ScreenerCategory.accumulation)

        # Silent accumulation: histogram improving on quiet (below-avg) volume.
        if (
            macd_hist is not None
            and macd_hist_prev is not None
            and macd_hist > macd_hist_prev
            and vr is not None
            and vr < 0.9
        ):
            cats.append(ScreenerCategory.accumulation_silent)

        # Pullback: uptrend (above SMA200) but RSI dipped into 35..50.
        if gt(close, sma200) and rsi is not None and 35 <= rsi <= 50:
            cats.append(ScreenerCategory.pullback)

        # Turnaround multibagger: deeply below SMA200 but momentum flipping up.
        if (
            sma200 is not None
            and close is not None
            and close < sma200 * 0.7
            and macd_hist is not None
            and macd_hist_prev is not None
            and macd_hist > macd_hist_prev
        ):
            cats.append(ScreenerCategory.turnaround_multibagger)

        # Frequently traded: sustained above-average volume.
        if vr is not None and vr >= 1.5:
            cats.append(ScreenerCategory.frequently_traded)

        # Short candidate: downtrend + overbought-ish bounce / weak structure.
        if gt(ema50, ema20) and rsi is not None and rsi >= 55:
            cats.append(ScreenerCategory.short_candidate)

        # ARA hunter (auto-reject-atas): very strong up momentum + volume surge.
        if rsi is not None and rsi >= 70 and vr is not None and vr >= 2.0:
            cats.append(ScreenerCategory.ara_hunter)

        return cats

    def _signal_and_score(self, ind: dict, cats: List[ScreenerCategory]):
        """Derive a BUY/HOLD/SELL signal and a 0..100 conviction score."""
        score = 50.0
        rsi = ind.get("rsi")
        close = ind.get("close")
        ema20 = ind.get("ema20")
        ema50 = ind.get("ema50")
        sma200 = ind.get("sma200")
        macd_hist = ind.get("macd_hist")

        if ema20 is not None and ema50 is not None:
            score += 12 if ema20 > ema50 else -12
        if close is not None and sma200 is not None:
            score += 10 if close > sma200 else -10
        if macd_hist is not None:
            score += 8 if macd_hist > 0 else -8
        if rsi is not None:
            if rsi < 30:
                score += 6  # oversold bounce potential
            elif rsi > 70:
                score -= 6  # overbought
        if ScreenerCategory.bullish in cats:
            score += 6
        if ScreenerCategory.bearish in cats:
            score -= 6

        score = max(0.0, min(100.0, score))
        if score >= 66:
            signal = "BUY"
        elif score >= 40:
            signal = "HOLD"
        else:
            signal = "SELL"
        return signal, round(score, 1)

    def _highlights(self, ind: dict) -> List[str]:
        def fmt(v, p=2):
            return f"{v:.{p}f}" if v is not None else "n/a"

        return [
            f"RSI(14): {fmt(ind.get('rsi'), 1)}",
            f"EMA20/EMA50: {fmt(ind.get('ema20'))} / {fmt(ind.get('ema50'))}",
            f"SMA200: {fmt(ind.get('sma200'))}",
            f"MACD hist: {fmt(ind.get('macd_hist'), 4)}",
            f"Volume ratio: {fmt(ind.get('volume_ratio'))}x",
            f"ATR%: {fmt(ind.get('atr_pct'))}",
        ]

    # -- public API --------------------------------------------------------

    def analyze(self, symbol: str, market: Market) -> AnalysisResult:
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "1y", "1d")
            ind = indicators.compute_all(df)
            if ind.get("close") is None:
                raise ValueError("insufficient data")
            cats = self.categorize(ind)
            signal, score = self._signal_and_score(ind, cats)
            tags = ", ".join(c.value for c in cats) or "none"
            return AnalysisResult(
                symbol=symbol.upper(),
                market=market,
                signal=signal,
                score=score,
                summary=(
                    f"{symbol.upper()} ({ticker}) on {market.value}: {signal} "
                    f"(score {score}). Tags: {tags}."
                ),
                highlights=self._highlights(ind),
                generated_at=_now_iso(),
            )
        except Exception as exc:  # noqa: BLE001 - intentional safe fallback
            logger.warning("analyze fell back to mock for %s: %s", ticker, exc)
            return mock_data.mock_analyze(symbol, market)

    def predict_weekly(self, symbol: str, market: Market) -> WeeklyPrediction:
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "6mo", "1d")
            ind = indicators.compute_all(df)
            close = ind.get("close")
            ema20 = ind.get("ema20")
            macd_hist = ind.get("macd_hist")
            atr_pct = ind.get("atr_pct")
            if close is None:
                raise ValueError("insufficient data")

            up_votes = 0
            if ema20 is not None and close > ema20:
                up_votes += 1
            if macd_hist is not None and macd_hist > 0:
                up_votes += 1
            rsi = ind.get("rsi")
            if rsi is not None and rsi > 50:
                up_votes += 1

            if up_votes >= 2:
                direction = "UP"
            elif up_votes == 0:
                direction = "DOWN"
            else:
                direction = "FLAT"

            # Expected move ~ weekly drift proxied by ATR% (bounded).
            base = atr_pct if atr_pct is not None else 1.0
            sign = 1 if direction == "UP" else (-1 if direction == "DOWN" else 0)
            expected = round(sign * min(base, 8.0), 2)
            confidence = round(0.4 + 0.2 * up_votes, 2)  # 0.4..1.0

            return WeeklyPrediction(
                symbol=symbol.upper(),
                direction=direction,
                expected_change_percent=expected,
                confidence=min(confidence, 1.0),
                rationale=(
                    f"{up_votes}/3 bullish factors (EMA20, MACD hist, RSI). "
                    f"Volatility (ATR%) {base:.2f}."
                ),
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("predict fell back to mock for %s: %s", ticker, exc)
            return mock_data.mock_predict_weekly(symbol)

    def screen(
        self, market: Market, symbols: Optional[List[str]] = None
    ) -> ScreenerResult:
        """Screen a market's symbol universe (or an explicit symbol list).

        Resolution order:
          1. explicit ``symbols`` argument, if given;
          2. the market's configured universe (CSV/Excel);
          3. mock screener output if neither yields a usable universe.
        """
        names: dict = {}
        if not symbols:
            symbols = self._universe.symbols(market)
            names = self._universe.names(market)

        if not symbols:
            return mock_data.mock_screen(market)

        matches: List[ScreenerMatch] = []
        for sym in symbols:
            ticker = yf_symbol(sym, market)
            try:
                df = self._fetch(ticker, "1y", "1d")
                ind = indicators.compute_all(df)
                if ind.get("close") is None:
                    raise ValueError("insufficient data")
                cats = self.categorize(ind)
                signal, score = self._signal_and_score(ind, cats)
                change_pct = _daily_change_pct(df)
                matches.append(
                    ScreenerMatch(
                        symbol=sym.upper(),
                        name=names.get(sym.upper(), sym.upper()),
                        score=score,
                        signal=signal,
                        price=round(ind["close"], 2),
                        change_percent=round(change_pct, 2),
                        categories=cats,
                    )
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("screen skipped %s: %s", ticker, exc)
                continue

        if not matches:
            return mock_data.mock_screen(market)

        matches.sort(key=lambda m: m.score, reverse=True)
        return ScreenerResult(
            market=market, matches=matches, generated_at=_now_iso()
        )


def _daily_change_pct(df: pd.DataFrame) -> float:
    close = df["Close"].dropna()
    if len(close) < 2:
        return 0.0
    prev, last = float(close.iloc[-2]), float(close.iloc[-1])
    return 0.0 if prev == 0 else (last - prev) / prev * 100
