"""行程內紀錄儲存。Demo 沒有外部 DB，只落地信封，永不存明文。"""

from __future__ import annotations

import threading

from app.errors import RecordNotFoundError


class RecordStore:
    """以 record_id 對應信封 wire 字串。加鎖是為了測試並行時不互相覆蓋。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._items: dict[str, str] = {}

    def put(self, record_id: str, envelope_wire: str) -> None:
        with self._lock:
            self._items[record_id] = envelope_wire

    def get(self, record_id: str) -> str:
        with self._lock:
            try:
                return self._items[record_id]
            except KeyError as exc:
                msg = "紀錄不存在"
                raise RecordNotFoundError("not_found", msg) from exc

    def __contains__(self, record_id: str) -> bool:
        with self._lock:
            return record_id in self._items
