"""Bind a native Codex stdio MCP call to the currently dispatched Cove turn.

Metadata is Codex-owned protocol data, never a tool argument or a permission by
itself. The caller must additionally authenticate the private MCP capability.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

from files import FILE_TOOLS
from storage import APIError


@dataclass(frozen=True)
class NativeCall:
    conversation: str
    thread: str
    turn: str
    call_id: str
    rpc_id: str | int
    tool: str
    arguments: dict


def bind_native_call(runtime, conversation, tool, arguments, metadata, rpc_id):
    """Fail closed unless all native IDs and the active dispatch agree."""
    if not isinstance(metadata, dict) or not isinstance(arguments, dict):
        raise APIError(400, '缺少原生 MCP 元数据或参数无效')
    if not isinstance(rpc_id, (str, int)) or isinstance(rpc_id, bool) or rpc_id == '':
        raise APIError(400, '原生 MCP 请求标识无效')
    call_id, thread = metadata.get('callId'), metadata.get('threadId')
    turn_meta = metadata.get('x-codex-turn-metadata')
    if (not isinstance(call_id, str) or not call_id or len(call_id) > 200 or
            not isinstance(thread, str) or not thread or
            not isinstance(turn_meta, dict) or
            turn_meta.get('thread_id') != thread or
            not isinstance(turn_meta.get('turn_id'), str) or not turn_meta['turn_id']):
        raise APIError(403, '原生 MCP 回合元数据不完整')
    if tool not in {entry['name'] for entry in FILE_TOOLS}:
        raise APIError(400, '文件工具参数无效')
    try:
        identity = json.dumps([tool, arguments], ensure_ascii=False, sort_keys=True,
                              separators=(',', ':'), allow_nan=False)
        identity = hashlib.sha256(identity.encode('utf-8')).hexdigest()
    except (TypeError, ValueError):
        raise APIError(400, '文件工具参数无效') from None
    with runtime.state_lock:
        active = runtime.active
        if (not active or active.get('conversation') != conversation or
                active.get('thread') != thread or active.get('turn') != turn_meta['turn_id'] or
                active.get('cancel') is None or active['cancel'].is_set()):
            raise APIError(409, '没有对应的活跃 Cove 原生回合')
        seen = getattr(runtime, '_native_mcp_calls', None)
        scope = (conversation, thread, turn_meta['turn_id'])
        if seen is None or getattr(runtime, '_native_mcp_scope', None) != scope:
            seen = runtime._native_mcp_calls = {}
            runtime._native_mcp_scope = scope
        previous = seen.get(call_id)
        if previous is not None and previous != (conversation, thread, turn_meta['turn_id'], identity):
            raise APIError(409, '原生 MCP callId 已用于不同请求')
        if previous is None and len(seen) >= 1024:
            raise APIError(409, '原生 MCP 回合调用记录已达上限')
        seen[call_id] = (conversation, thread, turn_meta['turn_id'], identity)
    return NativeCall(conversation, thread, turn_meta['turn_id'], call_id, rpc_id, tool, arguments)
