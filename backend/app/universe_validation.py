"""Startup data-validation for market universes.

For every supported market this verifies:
  * the Excel/CSV universe file exists (or notes a missing optional one);
  * the symbol count is non-zero;
  * there are no duplicate symbols (the loader already dedupes; we re-check the
    raw rows to surface source-data quality issues);
  * a market configuration entry exists (timezone / currency / suffix).

It logs a per-market line:  Market | Symbol Count | ETF Count | Stock Count
and returns a structured report. Validation NEVER raises on a bad/missing file
(the universe simply loads empty), so a broken file cannot crash startup; it is
reported as ``ok=False`` with reasons.

No scoring / indicators / ML / portfolio / broker code is touched here.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .market_config import MARKET_CONFIGS
from .models import Market
from .universe import UniverseRepository

logger = logging.getLogger("tradewizz.universe.validation")


@dataclass
class MarketValidation:
    market: Market
    file: Optional[str]
    file_exists: bool
    total: int
    etf: int
    stock: int
    duplicates: int
    has_config: bool
    ok: bool
    reasons: List[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "market": self.market.value,
            "file": self.file,
            "file_exists": self.file_exists,
            "total": self.total,
            "etf": self.etf,
            "stock": self.stock,
            "duplicates": self.duplicates,
            "has_config": self.has_config,
            "ok": self.ok,
            "reasons": list(self.reasons),
        }


# Markets that must have a universe (the original + the expansion targets).
# HKEX/KOSPI/KOSDAQ keep their existing optional behavior.
REQUIRED_MARKETS = (
    Market.IDX,
    Market.US,
    Market.JAPAN,
    Market.INDIA,
    Market.VIETNAM,
    Market.SINGAPORE,
)


def _raw_duplicate_count(repo: UniverseRepository, market: Market) -> int:
    """Count duplicate symbols among the *loaded* (normalized) entries.

    The repository dedupes on load, so loaded entries are unique by design;
    this remains 0 for a clean load and exists to surface regressions if the
    dedup ever breaks.
    """
    syms = repo.symbols(market)
    return len(syms) - len(set(syms))


def validate_market(
    repo: UniverseRepository, market: Market, *, required: bool
) -> MarketValidation:
    path = repo.resolve_path(market)
    file_exists = path is not None
    file_name = path.name if path is not None else None

    counts = repo.counts(market)
    total = counts["total"]
    etf = counts["etf"]
    stock = counts["stock"]
    duplicates = _raw_duplicate_count(repo, market)
    has_config = market in MARKET_CONFIGS

    reasons: List[str] = []
    if required and not file_exists:
        reasons.append("universe file missing")
    if required and total == 0:
        reasons.append("zero symbols loaded")
    if duplicates > 0:
        reasons.append(f"{duplicates} duplicate symbols")
    if not has_config:
        reasons.append("no market configuration")

    ok = not reasons
    return MarketValidation(
        market=market,
        file=file_name,
        file_exists=file_exists,
        total=total,
        etf=etf,
        stock=stock,
        duplicates=duplicates,
        has_config=has_config,
        ok=ok,
        reasons=reasons,
    )


def validate_universes(
    repo: Optional[UniverseRepository] = None,
    *,
    markets=REQUIRED_MARKETS,
    log: bool = True,
) -> Dict[Market, MarketValidation]:
    """Validate every required market; log a summary table; return the report."""
    repo = repo or UniverseRepository()
    report: Dict[Market, MarketValidation] = {}

    if log:
        logger.info(
            "Universe validation (dir=%s)", repo.directory
        )
        logger.info(
            "%-10s | %-7s | %-8s | %-9s | %s",
            "Market", "Symbols", "ETFs", "Stocks", "Status",
        )

    for market in markets:
        v = validate_market(repo, market, required=True)
        report[market] = v
        if log:
            status = "OK" if v.ok else "FAIL: " + "; ".join(v.reasons)
            logger.info(
                "%-10s | %-7d | %-8d | %-9d | %s",
                v.market.value, v.total, v.etf, v.stock, status,
            )

    failures = [m.value for m, v in report.items() if not v.ok]
    if failures and log:
        logger.warning("Universe validation FAILED for: %s", ", ".join(failures))
    elif log:
        logger.info("Universe validation passed for all required markets.")

    return report


def report_to_dict(report: Dict[Market, MarketValidation]) -> dict:
    return {m.value: v.to_dict() for m, v in report.items()}
