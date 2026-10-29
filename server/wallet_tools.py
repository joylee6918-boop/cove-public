"""Only Assistant wallet read/request, through observed app-server tool events.

No owner HTTP credential, native-metadata fallback, approval, or chat side effect.
Durable intent precedes dispatch to the separate wallet transaction. An uncertain
intent can only recover its original receipt, never dispatch again under a new ID.
"""
import hashlib
import json

from storage import APIError, encode
from wallet import amount, text

READ = 'cove_read_wallet'
REQUEST = 'cove_request_purchase'
WALLET_NAMES = {READ, REQUEST}
WALLET_TOOLS = [
    {'name': READ, 'description': 'Read only Assistant\'s virtual CNY wallet, including the explicit earningGuide, available/reserved funds and purchase statuses. Use earningGuide to understand which completed work can earn owner-decided pay. No other wallet, payments, credit or review authority. Daily allowance reconciliation is automatic accounting, not a model-awarded credit. Available only in the current ordinary Cove chat turn.',
     'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}},
    {'name': REQUEST, 'description': 'Create one purchase request for Assistant\'s virtual wallet in this ordinary Cove turn: integer amountFen and a short reason. Reserves funds only, never approves, debits or fulfills. 用户 decides only on the Home wallet page; never offer chat approval buttons. At most one creation attempt per turn. Do not repeat an uncertain request with a new call or in another turn: read the wallet and let the owner reconcile. Transport retries recover only the original tool-event receipt. No model-supplied ID, wallet selector, credit, review, deny or cancel.',
     'inputSchema': {'type': 'object', 'properties': {
         'amountFen': {'type': 'integer', 'minimum': 1, 'maximum': 100_000_000},
         'reason': {'type': 'string', 'minLength': 1, 'maxLength': 240}},
         'required': ['amountFen', 'reason'], 'additionalProperties': False}},
]


def exact(arguments):
    # JSON identity distinguishes bool/int/float; Python dict equality does not.
    return json.dumps(arguments, sort_keys=True, ensure_ascii=False, allow_nan=False)


def matches_event(permit, active, tool, arguments):
    return (permit.get('conversation') == active['conversation']
            and permit.get('thread') == active['thread']
            and permit.get('turn') == active['turn'] and permit.get('tool') == tool
            and isinstance(permit.get('call'), str) and bool(permit['call'])
            and exact(permit.get('arguments')) == exact(arguments))


def request_once(wallet, scope, event, arguments):
    """Called with runtime+chat locks held. Wallet intent and receipt are durable.

    No chat-db receipt is needed: both journals live in the separate wallet DB.
    A crash between intent and mutation conservatively leaves an unresolved intent.
    A crash/lost ACK after mutation recovers the exact committed wallet receipt.
    """
    identity = exact(arguments)
    request_id = 'model-' + hashlib.sha256(encode([scope, event]).encode()).hexdigest()
    with wallet.transaction():
        old = wallet.db.execute('SELECT * FROM model_requests WHERE scope=?', (scope,)).fetchone()
        if old:
            if old['event'] != event or old['arguments'] != identity or old['id'] != request_id:
                raise APIError(409, '本回合已有购买尝试；不得用新工具事件或参数重发，请读取钱包')
            receipt = wallet.db.execute('SELECT identity,result FROM receipts WHERE id=?', (request_id,)).fetchone()
            if receipt:
                expected = {'operation': 'request', 'body': dict(arguments, id=request_id)}
                if exact(json.loads(receipt['identity'])) != exact(expected):
                    raise APIError(409, '购买回执身份冲突；未重发')
                return json.loads(receipt['result'])
            rejected = wallet.db.execute('SELECT status,message FROM model_rejections WHERE id=?', (request_id,)).fetchone()
            if rejected:
                raise APIError(rejected['status'], rejected['message'])
            raise APIError(409, '购买结果不确定；仅可读取核对原请求，不能重新派发')
        unresolved = wallet.db.execute('''SELECT 1 FROM model_requests m
            LEFT JOIN receipts r ON r.id=m.id LEFT JOIN model_rejections e ON e.id=m.id
            WHERE r.id IS NULL AND e.id IS NULL LIMIT 1''').fetchone()
        if unresolved:
            raise APIError(409, '已有购买结果不确定；请由用户核对，不得创建新购买替代')
        # A lost callback ACK may leave a committed purchase rather than an
        # unresolved intent. A later turn must not recreate that same open wish.
        duplicate = next((p for p in wallet._purchases()
                          if p['status'] in ('requested', 'approved')
                          and p['amount'] == arguments['amountFen']
                          and p['reason'] == text(arguments['reason'])), None)
        if duplicate:
            raise APIError(409, '相同购买已有未结束请求 '+duplicate['id']+'；请读取核对，未创建新购买')
        wallet.db.execute('INSERT INTO model_requests VALUES(?,?,?,?)', (scope, event, identity, request_id))
    try:
        return wallet.mutate('request', dict(arguments, id=request_id))
    except APIError as error:
        # Definitive validation/state rejection, not transport/commit uncertainty.
        with wallet.transaction():
            wallet.db.execute('INSERT INTO model_rejections VALUES(?,?,?)', (request_id, error.status, error.message))
        raise
    except Exception:
        raise APIError(503, '购买结果不确定；未重发，请读取钱包核对原请求') from None


def execute_wallet(runtime, conversation, message, turn, call, tool, arguments):
    if tool == READ:
        if arguments:
            raise APIError(400, 'cove_read_wallet 只接受空参数 {}')
    elif tool == REQUEST:
        if set(arguments) != {'amountFen', 'reason'}:
            raise APIError(400, '购买请求仅接受 amountFen 与 reason')
        amount(arguments['amountFen']); text(arguments['reason'])
    else:
        raise APIError(403, '钱包模型工具无此权限')
    store = runtime.store
    # Lock order matches existing runtime -> Store paths. Hold through wallet
    # commit so finish/cancel/thread-switch cannot race authorization and mutation.
    with runtime.state_lock, store.lock:
        active = runtime.active
        if (not active or active['conversation'] != conversation or active['message'] != message
                or active['turn'] != turn or not turn or active['cancel'].is_set()):
            raise APIError(409, '钱包请求不属于当前 Cove 回合')
        if not any(p.get('used') and p.get('call') == call and matches_event(p, active, tool, arguments)
                   for p in runtime.file_permits):
            raise APIError(409, '钱包请求没有匹配的实际工具开始事件')
        origin = store._message(message)
        if (not origin or origin.get('role') != 'user' or message.startswith('pulse-cove-')
                or any(origin.get(k) for k in ('handoffID', 'healthRequestID', 'deviceActionID', 'aisayEventID'))):
            raise APIError(403, '钱包工具仅限普通聊天回合，不接受内部续答或唤醒')
        job = store.db.execute("SELECT 1 FROM jobs WHERE message=? AND turn=? AND state='running'", (message, turn)).fetchone()
        if (not job or origin.get('conversationID') != conversation
                or store.conversation(conversation)['thread'] != active['thread']):
            raise APIError(409, '钱包聊天回合已结束或线程不匹配')
        wallet = getattr(runtime, 'wallet', None)
        if wallet is None:
            raise APIError(503, '钱包尚未启用')
        if tool == READ:
            return wallet.snapshot()
        scope = encode([conversation, active['thread'], message, turn])
        return request_once(wallet, scope, call, arguments)
