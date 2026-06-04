"""Per-market symbol universes loaded from CSV/Excel.

Each market (IDX, HKEX, KOSPI, KOSDAQ) has a file under the universe directory
listing the symbols to screen. This keeps screening over a *controlled* list
instead of the whole exchange.

File resolution per market (first match wins), in `TRADEWIZ_UNIVERSE_DIR`
(default `backend/data/universe`):

    <market>.csv  e.g. idx.csv
    <market>.xlsx e.g. idx.xlsx

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


@dataclass(frozen=True)
class UniverseEntry:
    symbol: str
    name: str = ""


def _default_universe_dir() -> Path:
    env = os.environ.get("TRADEWIZ_UNIVERSE_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent / "data" / "universe"


def _read_table(path: Path) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in (".xlsx", ".xls"):
        return pd.read_excel(path, dtype=str)
    if suffix == ".csv":
        return pd.read_csv(path, dtype=str)
    raise ValueError(f"Unsupported universe file type: {path.name}")


def _pick_col(columns: List[str], candidates) -> Optional[str]:
    lower = {c.lower().strip(): c for c in columns}
    for cand in candidates:
        if cand in lower:
            return lower[cand]
    return None


def _entries_from_df(df: pd.DataFrame) -> List[UniverseEntry]:
    if df.empty:
        return []
    cols = [str(c) for c in df.columns]
    sym_col = _pick_col(cols, _SYMBOL_COLS)
    name_col = _pick_col(cols, _NAME_COLS)

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
        sym = str(raw).strip().upper()
        if not sym or sym in seen:
            continue
        seen.add(sym)
        name = ""
        if name_col is not None:
            nv = row.get(name_col)
            if nv is not None and not (isinstance(nv, float) and pd.isna(nv)):
                name = str(nv).strip()
        entries.append(UniverseEntry(symbol=sym, name=name))
    return entries


class UniverseRepository:
    """Loads and caches per-market symbol universes from disk."""

    def __init__(self, universe_dir: Optional[Path | str] = None):
        self._dir = Path(universe_dir) if universe_dir else _default_universe_dir()
        self._cache: Dict[Market, List[UniverseEntry]] = {}

    def _resolve_path(self, market: Market) -> Optional[Path]:
        stem = market.value.lower()
        for ext in (".csv", ".xlsx", ".xls"):
            p = self._dir / f"{stem}{ext}"
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
            entries = _entries_from_df(df)
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

    def reload(self) -> None:
        self._cache.clear()
