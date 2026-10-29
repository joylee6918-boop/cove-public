"""Assistant-only virtual CNY. No payment rails or chat side effects."""
import json
import re
import sqlite3
import threading
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from storage import APIError, encode

ZONE = ZoneInfo('Asia/Shanghai')
CATEGORIES = ('coding', 'bugfix', 'research', 'penwash', 'journal', 'writing',
              'bonus', 'gift', 'adjustment', 'refund')
MAX_AMOUNT = 100_000_000
MAX_BALANCE = 1_000_000_000_000
RECONCILE_DAYS = 366
EARNING_GUIDE = {
    'summary': '完成工作后可获得每日零用钱之外的报酬；用户可以事前悬赏，也可以事后打赏。',
    'rewardAuthority': '只有用户决定是否入账、收入类别和最终金额；Assistant 不能给自己发钱。',
    'opportunities': [
        {'category': 'coding', 'title': '写代码'},
        {'category': 'bugfix', 'title': '修 Bug'},
        {'category': 'research', 'title': '维护、调研与整理'},
        {'category': 'penwash', 'title': '钢笔淡彩'},
        {'category': 'journal', 'title': '手帐'},
        {'category': 'writing', 'title': '值得收藏的写作'},
        {'category': 'bonus', 'title': '额外奖金'},
        {'category': 'gift', 'title': '赠予'},
    ],
    'dailyAllowanceSeparate': True,
    'neverPriced': ['做爱', '亲密', '陪伴', '安慰', '拥抱', '亲吻', '说爱'],
}


def text(value, maximum=240):
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise APIError(400, '请填写有效说明')
    return value.strip()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        raise APIError(400, '钱包请求 ID 无效')
    return value


def amount(value, signed=False):
    if type(value) is not int or not 1 <= abs(value) <= MAX_AMOUNT or (value < 0 and not signed):
        raise APIError(400, '金额必须为整数分，非零且不超过 ¥1,000,000；仅更正允许负数')
    return value


class Wallet:
    def __init__(self, directory, clock=lambda: datetime.now(timezone.utc)):
        self.clock = clock
        self.lock = threading.RLock()
        path = Path(directory) / 'assistant-wallet.sqlite3'
        self.db = sqlite3.connect(path, timeout=10, check_same_thread=False, isolation_level=None)
        path.chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=DELETE;
            PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS ledger(
                id TEXT PRIMARY KEY, amount INTEGER NOT NULL CHECK(amount != 0),
                category TEXT NOT NULL, reason TEXT NOT NULL, day TEXT NOT NULL,
                created TEXT NOT NULL, purchase TEXT);
            CREATE INDEX IF NOT EXISTS ledger_day ON ledger(day);
            CREATE TABLE IF NOT EXISTS purchases(
                id TEXT PRIMARY KEY, amount INTEGER NOT NULL CHECK(amount > 0),
                reason TEXT NOT NULL, created TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS purchase_events(
                seq INTEGER PRIMARY KEY, purchase TEXT NOT NULL REFERENCES purchases(id),
                status TEXT NOT NULL, created TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS purchase_events_id ON purchase_events(purchase,seq);
            CREATE TABLE IF NOT EXISTS receipts(
                id TEXT PRIMARY KEY, identity TEXT NOT NULL, result TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS model_requests(
                scope TEXT PRIMARY KEY, event TEXT NOT NULL, arguments TEXT NOT NULL,
                id TEXT NOT NULL UNIQUE);
            CREATE TABLE IF NOT EXISTS model_rejections(
                id TEXT PRIMARY KEY, status INTEGER NOT NULL, message TEXT NOT NULL);
        ''')
        # Prevent accidental edits even from future service code. Corrections append.
        for table in ('ledger', 'purchases', 'purchase_events', 'receipts', 'model_requests', 'model_rejections'):
            for operation in ('UPDATE', 'DELETE'):
                self.db.execute(f'''CREATE TRIGGER IF NOT EXISTS {table}_no_{operation}
                    BEFORE {operation} ON {table} BEGIN SELECT RAISE(ABORT,'append only'); END''')
        with self.transaction():
            current = self.clock()
            day = current.astimezone(ZONE).date()
            self.db.execute("INSERT OR IGNORE INTO meta VALUES('createdAt',?)", (current.isoformat(),))
            self.db.execute("INSERT OR IGNORE INTO meta VALUES('through',?)", ((day-timedelta(days=1)).isoformat(),))

    @contextmanager
    def transaction(self):
        with self.lock:
            self.db.execute('BEGIN IMMEDIATE')
            try:
                yield
                self.db.execute('COMMIT')
            except BaseException:
                self.db.execute('ROLLBACK')
                raise

    def close(self):
        with self.lock:
            self.db.close()

    def _reconcile(self, current):
        today = current.astimezone(ZONE).date()
        through = date.fromisoformat(self.db.execute("SELECT value FROM meta WHERE key='through'").fetchone()[0])
        for _ in range(RECONCILE_DAYS):
            if through >= today:
                break
            through += timedelta(days=1)
            day = through.isoformat()
            self.db.execute('INSERT OR IGNORE INTO ledger VALUES(?,?,?,?,?,?,NULL)',
                            ('daily:'+day, 500, 'daily', '每日固定零用钱', day, current.isoformat()))
        self.db.execute("UPDATE meta SET value=? WHERE key='through'", (through.isoformat(),))
        return through < today

    def _purchases(self):
        return self.db.execute('''SELECT p.*, e.status, e.created AS updated FROM purchases p
            JOIN purchase_events e ON e.seq=(SELECT MAX(seq) FROM purchase_events WHERE purchase=p.id)
            ORDER BY e.seq DESC''').fetchall()

    def _totals(self):
        balance = self.db.execute('SELECT COALESCE(SUM(amount),0) FROM ledger').fetchone()[0]
        reserved = sum(p['amount'] for p in self._purchases() if p['status'] == 'requested')
        return balance, reserved

    def snapshot(self):
        with self.transaction():
            current = self.clock()
            pending = self._reconcile(current)
            day = current.astimezone(ZONE).date().isoformat()
            balance, reserved = self._totals()
            today = self.db.execute('SELECT amount FROM ledger WHERE day=?', (day,)).fetchall()
            activity = [{'id': r['id'], 'amountFen': r['amount'], 'category': r['category'],
                         'reason': r['reason'], 'day': r['day'], 'createdAt': r['created'],
                         'purchaseID': r['purchase']} for r in self.db.execute(
                             'SELECT * FROM ledger ORDER BY rowid DESC LIMIT 100')]
            purchases = self._purchases()
            # Always include all open requests/approved purchases, then 100 closed ones.
            opened = [r for r in purchases if r['status'] in ('requested', 'approved')]
            closed = [r for r in purchases if r['status'] not in ('requested', 'approved')][:100]
            return {'wallet': 'assistant', 'currency': 'CNY', 'virtual': True, 'day': day,
                    'updatedAt': current.isoformat(), 'balanceFen': balance, 'reservedFen': reserved,
                    'availableFen': balance-reserved, 'todayIncomeFen': sum(r[0] for r in today if r[0] > 0),
                    'todaySpendingFen': -sum(r[0] for r in today if r[0] < 0),
                    'allowancePending': pending, 'dailyAllowanceFen': 500,
                    'earningGuide': EARNING_GUIDE, 'activity': activity,
                    'earnings': [{'category': r[0], 'amountFen': r[1]} for r in self.db.execute(
                        'SELECT category,SUM(amount) FROM ledger WHERE amount>0 GROUP BY category ORDER BY category')],
                    'purchases': [{'id': r['id'], 'amountFen': r['amount'], 'reason': r['reason'],
                                   'status': r['status'], 'createdAt': r['created'], 'updatedAt': r['updated']}
                                  for r in opened+closed]}

    def mutate(self, operation, body):
        fields = {'credit': {'id', 'amountFen', 'category', 'reason'},
                  'request': {'id', 'amountFen', 'reason'},
                  'review': {'id', 'purchaseID', 'decision'}}
        if operation not in fields or not isinstance(body, dict) or set(body) != fields[operation]:
            raise APIError(400, '钱包参数无效')
        request_id = identifier(body['id'])
        if operation == 'credit':
            if body['category'] not in CATEGORIES:
                raise APIError(400, '收入类别无效；陪伴、亲密与爱不计价')
            amount(body['amountFen'], signed=body['category'] == 'adjustment')
            text(body['reason'])
        elif operation == 'request':
            amount(body['amountFen']); text(body['reason'])
        else:
            identifier(body['purchaseID'])
            if body['decision'] not in ('approve', 'deny', 'cancel', 'fulfill'):
                raise APIError(400, '购买决定无效')
        identity = json.dumps({'operation': operation, 'body': body}, sort_keys=True, ensure_ascii=False)
        with self.transaction():
            old = self.db.execute('SELECT identity,result FROM receipts WHERE id=?', (request_id,)).fetchone()
            if old:
                if old['identity'] != identity:
                    raise APIError(409, '此请求 ID 已用于不同操作；未重复记账')
                return json.loads(old['result'])
            current = self.clock()
            if self._reconcile(current):
                raise APIError(409, '每日零用钱尚在补记，请先刷新钱包')
            stamp, day = current.isoformat(), current.astimezone(ZONE).date().isoformat()
            balance, reserved = self._totals()
            result = {'id': request_id, 'operation': operation}
            if operation == 'credit':
                value = body['amountFen']
                if balance+value < reserved or balance+value > MAX_BALANCE:
                    raise APIError(409, '可用余额不足或超出钱包上限')
                self.db.execute('INSERT INTO ledger VALUES(?,?,?,?,?,?,NULL)',
                                ('owner:'+request_id, value, body['category'], text(body['reason']), day, stamp))
            elif operation == 'request':
                if body['amountFen'] > balance-reserved:
                    raise APIError(409, '可用余额不足，未预留')
                if sum(p['status'] in ('requested', 'approved') for p in self._purchases()) >= 100:
                    raise APIError(409, '待处理购买过多，请先处理已有请求')
                self.db.execute('INSERT INTO purchases VALUES(?,?,?,?)',
                                (request_id, body['amountFen'], text(body['reason']), stamp))
                self.db.execute('INSERT INTO purchase_events(purchase,status,created) VALUES(?,?,?)',
                                (request_id, 'requested', stamp))
                result['purchaseID'] = request_id
            else:
                purchase = next((p for p in self._purchases() if p['id'] == body['purchaseID']), None)
                if purchase is None:
                    raise APIError(404, '购买请求不存在')
                target = {'approve': 'approved', 'deny': 'denied', 'cancel': 'cancelled', 'fulfill': 'fulfilled'}[body['decision']]
                source = 'approved' if target == 'fulfilled' else 'requested'
                if purchase['status'] != source:
                    raise APIError(409, '购买状态已改变，请刷新；未再次扣款')
                if target == 'approved':
                    self.db.execute('INSERT INTO ledger VALUES(?,?,?,?,?,?,?)',
                                    ('purchase:'+purchase['id'], -purchase['amount'], 'purchase',
                                     purchase['reason'], day, stamp, purchase['id']))
                self.db.execute('INSERT INTO purchase_events(purchase,status,created) VALUES(?,?,?)',
                                (purchase['id'], target, stamp))
                result.update(purchaseID=purchase['id'], status=target)
            self.db.execute('INSERT INTO receipts VALUES(?,?,?)', (request_id, identity, encode(result)))
            return result
