"""Broker-connection service: per-user connect/list/disconnect + validation."""

from __future__ import annotations

from typing import List, Optional

from .models import (
    IMPLEMENTED_BROKERS,
    BrokerConnection,
    BrokerType,
    DisconnectResult,
)
from .store import ConnectionStore, SqliteConnectionStore


class ConnectionError_(Exception):
    """Connection validation failure -> mapped to an HTTP error."""

    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


_DEFAULT_NAMES = {
    BrokerType.MOOMOO: "Moomoo",
    BrokerType.IBKR: "Interactive Brokers",
}


class BrokerConnectionService:
    def __init__(
        self,
        store: Optional[ConnectionStore] = None,
        db_path: Optional[str] = None,
    ):
        if store is not None:
            self._store = store
        else:
            from ..auth.config import AuthConfig

            self._store = SqliteConnectionStore(
                db_path or AuthConfig.from_env().db_path
            )

    @property
    def store(self) -> ConnectionStore:
        return self._store

    def list(self, user_id: int) -> List[BrokerConnection]:
        return [self._to_model(r) for r in self._store.list_for_user(user_id)]

    def count_active(self, user_id: int) -> int:
        return self._store.count_active(user_id)

    def connect(
        self,
        user_id: int,
        broker_type: BrokerType,
        display_name: Optional[str] = None,
    ) -> BrokerConnection:
        if broker_type not in IMPLEMENTED_BROKERS:
            raise ConnectionError_(
                f"{broker_type.value} is not available yet.", status_code=400
            )
        if self._store.exists_active(user_id, broker_type):
            raise ConnectionError_(
                f"{broker_type.value} is already connected.", status_code=409
            )
        name = (display_name or "").strip() or _DEFAULT_NAMES.get(
            broker_type, broker_type.value
        )
        rec = self._store.create(user_id, broker_type, name)
        return self._to_model(rec)

    def disconnect(self, user_id: int, conn_id: int) -> DisconnectResult:
        rec = self._store.get(conn_id)
        if rec is None or rec.user_id != user_id:
            raise ConnectionError_("Connection not found.", status_code=404)
        ok = self._store.delete(conn_id, user_id)
        return DisconnectResult(
            id=conn_id, disconnected=ok,
            message="Disconnected." if ok else "Could not disconnect.",
        )

    @staticmethod
    def _to_model(rec) -> BrokerConnection:
        return BrokerConnection(
            id=rec.id,
            user_id=rec.user_id,
            broker_type=BrokerType(rec.broker_type),
            display_name=rec.display_name,
            is_active=rec.is_active,
            created_at=rec.created_at,
        )
