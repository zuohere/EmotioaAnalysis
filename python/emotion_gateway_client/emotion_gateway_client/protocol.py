from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any, Dict, Optional
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse


ISO_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime(ISO_FORMAT)


def build_gateway_ws_url(base_url: str, token: Optional[str]) -> str:
    """将 token 以 query 参数形式附加到 WS URL（若 URL 未显式包含 token=...）。"""
    if not token:
        return base_url
    parsed = urlparse(base_url)
    query_items = dict(parse_qsl(parsed.query, keep_blank_values=True))
    if query_items.get("token"):
        return base_url
    query_items["token"] = token
    new_query = urlencode(query_items, doseq=True)
    return urlunparse(parsed._replace(query=new_query))


def build_gateway_headers(token: Optional[str], token_in_header: bool) -> Optional[Dict[str, str]]:
    if not token or not token_in_header:
        return None
    return {"Authorization": f"Bearer {token}"}


def dumps_message(message_type: str, payload: Any) -> str:
    msg = {"message_type": message_type, "payload": payload}
    return json.dumps(msg, ensure_ascii=False)

