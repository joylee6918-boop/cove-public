"""Temporary local databases and actual route dispatch only; no model/network calls."""
import io
import json
import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

from cove import Application
from storage import APIError, Store
from wallet import Wallet


class WalletTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.time = datetime(2026, 10, 21, 15, 59, tzinfo=timezone.utc)
        self.wallet = Wallet(self.temp.name, lambda: self.time)

    def tearDown(self):
        self.wallet.close()
        self.temp.cleanup()

    def credit(self, id='reward', value=123, category='coding'):
        return self.wallet.mutate('credit', dict(id=id, amountFen=value, category=category, reason='已完成修复'))

    def request(self, id='purchase', value=300):
        return self.wallet.mutate('request', dict(id=id, amountFen=value, reason='买一本书'))

    def review(self, decision, id=None, purchase='purchase'):
        return self.wallet.mutate('review', dict(id=id or decision, purchaseID=purchase, decision=decision))

    def test_snapshot_exposes_earning_guide_to_assistant(self):
        guide = self.wallet.snapshot()['earningGuide']
        self.assertEqual([item['category'] for item in guide['opportunities']],
                         ['coding', 'bugfix', 'research', 'penwash', 'journal', 'writing', 'bonus', 'gift'])
        self.assertIn('用户', guide['rewardAuthority'])
        self.assertTrue(guide['dailyAllowanceSeparate'])
        self.assertIn('陪伴', guide['neverPriced'])

    def test_beijing_midnight_missed_days_restart_and_exact_fen(self):
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 500)
        self.time += timedelta(minutes=2)
        self.credit(value=101)
        snapshot = self.wallet.snapshot()
        self.assertEqual((snapshot['balanceFen'], snapshot['todayIncomeFen'], snapshot['day']), (1101, 601, '2026-10-22'))
        self.time += timedelta(days=3)
        self.wallet.close()
        self.wallet = Wallet(self.temp.name, lambda: self.time)
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 2601)
        self.assertEqual(len([r for r in self.wallet.snapshot()['activity'] if r['category'] == 'daily']), 5)
        self.credit(value=101)  # durable identical retry after restart
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 2601)

    def test_concurrent_get_across_independent_connections_pays_once(self):
        other = Wallet(self.temp.name, lambda: self.time)
        try:
            with ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda i: (self.wallet if i % 2 else other).snapshot(), range(32)))
            self.assertEqual({r['balanceFen'] for r in results}, {500})
            self.assertEqual(len(self.wallet.snapshot()['activity']), 1)
        finally:
            other.close()

    def test_bounded_reconciliation_reports_incomplete_then_catches_up(self):
        self.time += timedelta(days=400)
        self.assertTrue(self.wallet.snapshot()['allowancePending'])
        result = self.wallet.snapshot()
        self.assertFalse(result['allowancePending'])
        self.assertEqual(result['balanceFen'], 401 * 500)
        # Backward clock never pays a date twice.
        self.time -= timedelta(days=20)
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 401 * 500)

    def test_reservation_approval_fulfillment_exactly_once(self):
        self.request()
        result = self.wallet.snapshot()
        self.assertEqual((result['balanceFen'], result['reservedFen'], result['availableFen']), (500, 300, 200))
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.review('approve'), range(16)))
        self.assertTrue(all(r == results[0] for r in results))
        result = self.wallet.snapshot()
        self.assertEqual((result['balanceFen'], result['reservedFen'], result['todaySpendingFen']), (200, 0, 300))
        self.review('fulfill')
        self.assertEqual(self.wallet.snapshot()['purchases'][0]['status'], 'fulfilled')
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 200)
        for decision in ('approve', 'deny', 'cancel', 'fulfill'):
            with self.assertRaises(APIError): self.review(decision, id='new-'+decision)
        self.wallet.close()
        self.wallet = Wallet(self.temp.name, lambda: self.time)
        self.review('approve')  # old successful receipt, not a new state transition
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 200)

    def test_deny_cancel_release_and_insufficient_funds_never_overdraw(self):
        self.request(value=500)
        with self.assertRaises(APIError): self.request('second', 1)
        with self.assertRaises(APIError): self.credit('correction', -1, 'adjustment')
        self.review('deny')
        self.request('second', 500)
        self.review('cancel', purchase='second')
        self.assertEqual(self.wallet.snapshot()['availableFen'], 500)
        with self.assertRaises(APIError): self.request('third', 501)
        with self.assertRaises(APIError): self.review('fulfill', purchase='second')

    def test_competing_spend_requests_cannot_reserve_same_funds(self):
        def run(i):
            try:
                self.request('request'+str(i), 400)
                return True
            except APIError:
                return False
        with ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(sum(pool.map(run, range(16))), 1)
        self.assertEqual(self.wallet.snapshot()['availableFen'], 100)

    def test_atomic_review_failure_rolls_back_deduction_and_can_retry(self):
        self.request(value=300)
        self.wallet.db.execute('''CREATE TRIGGER fail_receipt BEFORE INSERT ON receipts
            WHEN NEW.id='approve' BEGIN SELECT RAISE(ABORT,'synthetic failed commit'); END''')
        with self.assertRaises(sqlite3.IntegrityError): self.review('approve')
        result = self.wallet.snapshot()
        self.assertEqual((result['balanceFen'], result['reservedFen']), (500, 300))
        self.assertEqual(result['purchases'][0]['status'], 'requested')
        self.wallet.db.execute('DROP TRIGGER fail_receipt')
        self.review('approve')
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 200)

    def test_distinct_connections_race_approval_and_denial(self):
        self.request(value=500)
        other = Wallet(self.temp.name, lambda: self.time)
        def review(pair):
            wallet, decision = pair
            try:
                wallet.mutate('review', dict(id=decision, purchaseID='purchase', decision=decision))
                return True
            except APIError:
                return False
        try:
            with ThreadPoolExecutor(max_workers=2) as pool:
                self.assertEqual(sum(pool.map(review, [(self.wallet, 'approve'), (other, 'deny')])), 1)
            snapshot = self.wallet.snapshot()
            status = snapshot['purchases'][0]['status']
            self.assertEqual(snapshot['balanceFen'], 0 if status == 'approved' else 500)
            self.assertEqual(snapshot['reservedFen'], 0)
        finally:
            other.close()

    def test_credit_id_conflict_key_order_and_compensating_entry(self):
        result = self.credit()
        reordered = dict(reason='已完成修复', category='coding', amountFen=123, id='reward')
        self.assertEqual(self.wallet.mutate('credit', reordered), result)
        with self.assertRaises(APIError): self.credit(value=124)
        with self.assertRaises(APIError): self.request('reward', 123)
        self.credit('correction', -23, 'adjustment')
        self.credit('refund', 1, 'refund')
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 601)
        with self.assertRaises(sqlite3.IntegrityError):
            self.wallet.db.execute("UPDATE ledger SET amount=999 WHERE id='owner:reward'")
        with self.assertRaises(sqlite3.IntegrityError): self.wallet.db.execute('DELETE FROM ledger')
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 601)

    def test_validation_no_float_bool_zero_unknown_fields_or_affection_category(self):
        for bad in (True, 1.1, '100', 0, -1, 100_000_001):
            with self.subTest(bad=bad), self.assertRaises(APIError): self.credit(value=bad)
        for category in ('sex', 'affection', [], None):
            with self.assertRaises(APIError): self.credit(category=category)
        body = dict(id='credit', amountFen=100, reason='完成工作', category='coding')
        for invalid in (dict(body, owner='ian'), dict(body, reason=''), dict(body, reason='x\n'), dict(body, id='../x')):
            with self.assertRaises(APIError): self.wallet.mutate('credit', invalid)
        self.assertEqual(self.wallet.snapshot()['balanceFen'], 500)

    def test_private_independent_database(self):
        from pathlib import Path
        path = Path(self.temp.name) / 'assistant-wallet.sqlite3'
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with tempfile.TemporaryDirectory() as directory:
            other = Wallet(directory, lambda: self.time)
            try:
                self.credit(value=100)
                self.assertEqual(other.snapshot()['balanceFen'], 500)
            finally:
                other.close()


class WalletRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(self.temp.name)
        self.owner = 'synthetic-wallet-owner-token-0000000'
        self.shortcut = 'synthetic-wallet-shortcut-token-00000'
        self.app = Application(self.store, self.owner, shortcuts_token=self.shortcut)

    def tearDown(self):
        self.app.close(); self.store.close(); self.temp.cleanup()

    def call(self, method, path, token=None, body=None):
        cls = self.app.handler()
        handler = cls.__new__(cls)
        handler.command, handler.path = method, path
        data = json.dumps(body).encode() if body is not None else b''
        handler.headers = {'Content-Length': str(len(data)), 'Authorization': 'Bearer '+(token or '')}
        handler.rfile = io.BytesIO(data)
        try:
            return 200, handler.route()
        except APIError as exc:
            return exc.status, exc.message

    def test_only_owner_can_read_credit_request_or_review_no_model_wake(self):
        credit = dict(id='credit', amountFen=1, reason='修复完成', category='bugfix')
        for token in (None, self.shortcut, 'synthetic-model-capability'):
            for path in ('credit', 'request', 'review'):
                self.assertEqual(self.call('POST', '/v1/wallet/'+path, token, credit)[0], 401)
            self.assertEqual(self.call('GET', '/v1/wallet', token)[0], 401)
        self.assertEqual(self.call('POST', '/v1/wallet/credit', self.owner, credit)[0], 200)
        status, result = self.call('GET', '/v1/wallet', self.owner)
        self.assertEqual((status, result['wallet'], result['balanceFen']), (200, 'assistant', 501))
        self.assertEqual(self.store.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
        self.assertFalse(self.app.wake.is_set())

    def test_route_lifecycle_and_limits(self):
        request = dict(id='request', amountFen=100, reason='书')
        self.assertEqual(self.call('POST', '/v1/wallet/request', self.owner, request)[0], 200)
        review = dict(id='review', purchaseID='request', decision='approve')
        self.assertEqual(self.call('POST', '/v1/wallet/review', self.owner, review)[0], 200)
        self.assertEqual(self.call('POST', '/v1/wallet/review', self.owner, review)[0], 200)
        self.assertEqual(self.call('GET', '/v1/wallet', self.owner)[1]['balanceFen'], 400)
        self.assertEqual(self.call('GET', '/v1/wallet?owner=ian', self.owner)[0], 400)
        self.assertEqual(self.call('DELETE', '/v1/wallet', self.owner)[0], 404)
        self.assertEqual(self.call('POST', '/v1/wallet/credit', self.owner, {'large': 'x'*2048})[0], 413)


if __name__ == '__main__':
    unittest.main()
