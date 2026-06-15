"""Per-market symbol universes loaded from CSV/Excel.

Each market (IDX, HKEX, KOSPI, KOSDAQ) has a file under the universe directory
listing the symbols to screen. This keeps screening over a *controlled* list
instead of the whole exchange.

Primary source is the **Excel** export (more complete); CSV is the fallback.
Resolution per market (first match wins), in `TRADEWIZ_UNIVERSE_DIR`
(default `backend/data/universe`):

    <market>.xlsx  e.g. idx.xlsx   (preferred / primary)
    <market>.csv   e.g. idx.csv    (fallback)

Because the legacy Excel exports are raw and not market-clean, a per-market
**normalization** step runs on load:

- symbols are stripped of the market's yfinance suffix (.JK/.HK/.KS/.KQ) so the
  stored value is bare (matching `yf_symbol`, which re-appends idempotently);
- **HKEX**: keep ordinary-equity codes only (1..9999), dropping warrants/CBBCs/
  DRs that dominate the raw file;
- **KOSPI/KOSDAQ**: the raw `kospi.xlsx` is a *combined Korea* file, so rows are
  routed by source suffix — `.KS` -> KOSPI, `.KQ` -> KOSDAQ. KOSDAQ falls back
  to reading `kospi.xlsx` when no `kosdaq.xlsx` exists.

Expected columns (case-insensitive): a symbol column named one of
`symbol`, `ticker`, `code`; an optional `name` column. A header-less
single-column file is also accepted (each row treated as a symbol).
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import pandas as pd

from .models import Market

logger = logging.getLogger("tradewiz.universe")

_SYMBOL_COLS = ("symbol", "ticker", "code")
_NAME_COLS = ("name", "company", "company_name")
# Board-listing column (STK vs ETF) used for diagnostics counts. The prepared
# global-market Excel exports carry "Papan Pencatatan" with values STK / ETF.
_BOARD_COLS = ("papan pencatatan", "board", "type", "instrument_type")

# yfinance-style suffix per market (also what raw Excel symbols carry).
# Derived from the single source of truth (market_config) so a new market needs
# only one table edit. US has an empty suffix (bare symbols).
from .market_config import MARKET_CONFIGS as _MARKET_CONFIGS

_MARKET_SUFFIX = {m: cfg.yahoo_suffix for m, cfg in _MARKET_CONFIGS.items()}

# HKEX ordinary-equity board code range (exclude warrants/CBBC/DR/etc.).
_HKEX_EQUITY_MIN = 1
_HKEX_EQUITY_MAX = 9999

# --- US symbol normalization ---------------------------------------------- #
# The raw US universe export uses feed-style notation that Yahoo Finance does
# NOT accept, producing nothing but 404 / no-data responses (pure noise that
# also burns the shared Yahoo rate limit and slows the full-universe screen):
#   * preferred shares use '$' (e.g. AGM$D); Yahoo's '-' form (AGM-D) is also
#     not covered by yfinance, so these are dropped entirely.
#   * warrants/units/rights use '.W' / '.U' / '.R'; these are not covered.
# Class shares (.A/.B/.C/.V, e.g. BRK.A) ARE covered, but Yahoo spells them
# with a dash (BRK-A), so we convert '.' -> '-' for those.
# Empirically verified against Yahoo (2026-06-15): all sampled '$' and
# '.W'/'.U'/'.R' returned no data; sampled '.A'/'.B' returned data once dashed.
_US_DROP_DOT_SUFFIXES = (".W", ".U", ".R")


@dataclass(frozen=True)
class UniverseEntry:
    symbol: str
    name: str = ""
    is_etf: bool = False


def _default_universe_dir() -> Path:
    env = os.environ.get("TRADEWIZ_UNIVERSE_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent / "data" / "universe"


def _read_table(path: Path) -> pd.DataFrame:
    """Read a universe file into a single DataFrame.

    Excel files may carry MULTIPLE sheets (e.g. ALL_US / NASDAQ / NYSE / ETF).
    All sheets are read and concatenated; duplicate symbols are deduped later
    in ``_entries_from_df``. A combined "ALL_*" sheet (when present) is enough
    on its own, but reading every sheet guarantees no symbol is missed even if
    a file lacks an aggregate sheet.
    """
    suffix = path.suffix.lower()
    if suffix in (".xlsx", ".xls"):
        sheets = pd.read_excel(path, dtype=str, sheet_name=None)  # dict
        frames = [df for df in sheets.values() if df is not None and not df.empty]
        if not frames:
            return pd.DataFrame()
        return pd.concat(frames, ignore_index=True, sort=False)
    if suffix == ".csv":
        return pd.read_csv(path, dtype=str)
    raise ValueError(f"Unsupported universe file type: {path.name}")


def _pick_col(columns: List[str], candidates) -> Optional[str]:
    lower = {c.lower().strip(): c for c in columns}
    for cand in candidates:
        if cand in lower:
            return lower[cand]
    return None


def _source_suffix(raw: str) -> Optional[str]:
    """Return the trailing market suffix of a raw symbol (e.g. '.KQ'), or None."""
    r = raw.strip().upper()
    dot = r.rfind(".")
    return r[dot:] if dot != -1 else None


def _strip_suffix(raw: str, market: Optional[Market]) -> str:
    """Strip the market's yfinance suffix so the stored symbol is bare."""
    sym = raw.strip().upper()
    if market is not None:
        suffix = _MARKET_SUFFIX.get(market)
        # Guard: empty suffix (US) must never truncate the symbol.
        if suffix and sym.endswith(suffix):
            sym = sym[: -len(suffix)]
    return sym


def _normalize_us_symbol(raw: str) -> Optional[str]:
    """Normalize a raw US ticker for Yahoo, or return None to drop it.

    * Drop preferred shares ('$') and warrants/units/rights ('.W'/'.U'/'.R'):
      Yahoo/yfinance does not cover them, so they only generate 404/no-data
      noise and waste the rate limit.
    * Convert class-share dots to dashes (BRK.A -> BRK-A) so the covered
      class shares resolve correctly.
    """
    sym = raw.strip().upper()
    if not sym:
        return None
    if "$" in sym:
        return None
    for suf in _US_DROP_DOT_SUFFIXES:
        if sym.endswith(suf):
            return None
    return sym.replace(".", "-")


def _hkex_is_equity(bare_symbol: str) -> bool:
    """True for HKEX ordinary-equity board codes (1..9999)."""
    digits = "".join(ch for ch in bare_symbol if ch.isdigit())
    if not digits:
        return False
    try:
        code = int(digits)
    except ValueError:
        return False
    return _HKEX_EQUITY_MIN <= code <= _HKEX_EQUITY_MAX


def _entries_from_df(
    df: pd.DataFrame, market: Optional[Market] = None
) -> List[UniverseEntry]:
    if df.empty:
        return []
    cols = [str(c) for c in df.columns]
    sym_col = _pick_col(cols, _SYMBOL_COLS)
    name_col = _pick_col(cols, _NAME_COLS)
    board_col = _pick_col(cols, _BOARD_COLS)

    # Header-less single column (e.g. read with a generated header): treat the
    # only column as the symbol column.
    if sym_col is None and len(cols) == 1:
        sym_col = cols[0]

    if sym_col is None:
        raise ValueError(
            f"No symbol column found (looked for {_SYMBOL_COLS}); columns={cols}"
        )

    entries: List[UniverseEntry] = []
    seen = set()
    for _, row in df.iterrows():
        raw = row.get(sym_col)
        if raw is None or (isinstance(raw, float) and pd.isna(raw)):
            continue
        raw = str(raw).strip()
        if not raw:
            continue

        # --- per-market normalization / routing ---
        if market in (Market.KOSPI, Market.KOSDAQ):
            # Raw Korea file mixes .KS (KOSPI) and .KQ (KOSDAQ): route by suffix.
            src = _source_suffix(raw)
            want = _MARKET_SUFFIX[market]
            # If a row carries an explicit Korea suffix, keep only the matching
            # market; rows without a suffix are accepted (assume correct file).
            if src in (".KS", ".KQ") and src != want:
                continue

        if market is Market.US:
            sym = _normalize_us_symbol(raw)
            if sym is None:
                continue  # drop preferred ($) and warrant/unit/right (.W/.U/.R)
        else:
            sym = _strip_suffix(raw, market)
        if not sym:
            continue

        if market is Market.HKEX and not _hkex_is_equity(sym):
            continue  # drop warrants/CBBC/DR/etc.

        if sym in seen:
            continue
        seen.add(sym)

        name = ""
        if name_col is not None:
            nv = row.get(name_col)
            if nv is not None and not (isinstance(nv, float) and pd.isna(nv)):
                name = str(nv).strip()

        is_etf = False
        if board_col is not None:
            bv = row.get(board_col)
            if bv is not None and not (isinstance(bv, float) and pd.isna(bv)):
                is_etf = str(bv).strip().upper() == "ETF"

        entries.append(UniverseEntry(symbol=sym, name=name, is_etf=is_etf))
    return entries


class UniverseRepository:
    """Loads and caches per-market symbol universes from disk."""

    def __init__(self, universe_dir: Optional[Path | str] = None):
        self._dir = Path(universe_dir) if universe_dir else _default_universe_dir()
        self._cache: Dict[Market, List[UniverseEntry]] = {}

    def _resolve_path(self, market: Market) -> Optional[Path]:
        """Resolve a universe file, preferring Excel (primary) over CSV.

        KOSDAQ falls back to the combined `kospi.xlsx` (the raw Korea export)
        when no dedicated KOSDAQ file exists; routing-by-suffix then extracts
        the `.KQ` rows.
        """
        stem = market.value.lower()
        # Excel first (more complete) ...
        for ext in (".xlsx", ".xls"):
            p = self._dir / f"{stem}{ext}"
            if p.exists():
                return p
        # ... then, for KOSDAQ, the combined Korea Excel (preferred over CSV) ...
        if market is Market.KOSDAQ:
            for ext in (".xlsx", ".xls"):
                p = self._dir / f"kospi{ext}"
                if p.exists():
                    return p
        # ... finally CSV fallback.
        p = self._dir / f"{stem}.csv"
        if p.exists():
            return p
        return None

    def entries(self, market: Market) -> List[UniverseEntry]:
        """Return the universe for a market (empty list if no/invalid file)."""
        if market in self._cache:
            return self._cache[market]

        path = self._resolve_path(market)
        if path is None:
            logger.info("No universe file for %s in %s", market.value, self._dir)
            self._cache[market] = []
            return []

        try:
            df = _read_table(path)
            entries = _entries_from_df(df, market)
            logger.info("Loaded %d symbols for %s from %s",
                        len(entries), market.value, path.name)
        except Exception as exc:  # noqa: BLE001 - bad file -> empty universe
            logger.warning("Failed to load universe %s: %s", path, exc)
            entries = []

        self._cache[market] = entries
        return entries

    def symbols(self, market: Market) -> List[str]:
        return [e.symbol for e in self.entries(market)]

    def names(self, market: Market) -> Dict[str, str]:
        return {e.symbol: e.name for e in self.entries(market) if e.name}

    def counts(self, market: Market) -> Dict[str, int]:
        """Symbol / ETF / stock counts for a market (diagnostics)."""
        entries = self.entries(market)
        etf = sum(1 for e in entries if e.is_etf)
        return {
            "total": len(entries),
            "etf": etf,
            "stock": len(entries) - etf,
        }

    def resolve_path(self, market: Market) -> Optional[Path]:
        """Public accessor for the resolved universe file path (validation)."""
        return self._resolve_path(market)

    @property
    def directory(self) -> Path:
        return self._dir

    def reload(self) -> None:
        self._cache.clear()
