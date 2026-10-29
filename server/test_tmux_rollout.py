import json
import os
import tempfile
import unittest
from pathlib import Path

from tmux_rollout import RolloutTailer, RolloutUnsafe, RolloutObserver


THREAD = 'thread-current'
TURN = 'turn-current'


def entry(kind, **payload):
    return (json.dumps({'type': kind, 'payload': payload}, ensure_ascii=False) + '\n').encode()


class RolloutTailerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve()
        (self.home / 'sessions').mkdir()
        self.path = self.home / 'sessions' / 'rollout.jsonl'
        self.path.write_bytes(entry('event_msg', type='task_complete', turn_id='old'))
        self.tailer = RolloutTailer(self.home, self.path, THREAD, TURN)

    def tearDown(self):
        self.tailer.close()
        self.temp.cleanup()

    def append(self, data):
        with self.path.open('ab') as stream:
            stream.write(data)

    def test_partial_utf8_and_per_instance_cursor_no_history_replay(self):
        start = entry('event_msg', type='task_started', turn_id=TURN)
        message = entry('response_item', type='message', role='assistant', phase='final',
                        content=[{'type': 'output_text', 'text': '你好'}])
        split = message.index('你'.encode()) + 1
        self.append(start + message[:split])
        self.assertEqual([e.kind for e in self.tailer.poll()], ['turn_started'])
        self.assertGreater(self.tailer.snapshot().pending_bytes, 0)
        self.assertEqual(self.tailer.poll(), [])
        self.append(message[split:])
        self.assertEqual(self.tailer.poll()[0].text, '你好')
        self.assertEqual(self.tailer.poll(), [])

    def test_large_native_image_receipt_is_not_a_filename_or_chat_text(self):
        self.tailer.MAX_LINE_BYTES = 1024 * 1024
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.append(entry('response_item', type='message', role='user',
                          content=[{'type': 'input_text', 'text': '/tmp/not-an-image.png'},
                                   {'type': 'input_image', 'image_url': 'data:image/png;base64,' + 'x' * 90000}]))
        events = self.tailer.poll()
        self.assertEqual([(event.kind, event.label) for event in events],
                         [('turn_started', None), ('image_input', '1')])
        self.assertIsNone(events[-1].text)

    def test_only_selected_turn_final_message_and_explicit_complete(self):
        self.append(entry('event_msg', type='task_started', turn_id='other'))
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'wrong'}]))
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.append(entry('response_item', type='message', role='assistant', phase='analysis',
                          content=[{'type': 'output_text', 'text': 'secret reasoning'}]))
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'input_text', 'text': 'not output'}]))
        self.append(entry('response_item', type='custom_tool_call', name='secret', input='secret args'))
        self.append(entry('response_item', type='custom_tool_call_output', output='secret tool output'))
        self.append(entry('event_msg', type='item_completed', thread_id='other', turn_id=TURN,
                          item={'type': 'mcpToolCall', 'arguments': {'secret': True}}))
        self.append(entry('event_msg', type='item_completed', thread_id=THREAD, turn_id=TURN,
                          item={'type': 'mcpToolCall', 'arguments': {'secret': True}}))
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'safe'}]))
        self.append(entry('event_msg', type='task_complete', turn_id='other', last_agent_message='wrong'))
        events = self.tailer.poll()
        self.assertEqual([e.kind for e in events],
                         ['turn_started', 'tool_started', 'tool_completed', 'tool_completed', 'message'])
        self.assertEqual([e.text for e in events if e.kind == 'message'], ['safe'])
        self.assertNotIn('secret', repr(events))
        self.append(entry('event_msg', type='task_complete', turn_id=TURN, last_agent_message='safe'))
        self.assertEqual([(e.kind, e.text) for e in self.tailer.poll()], [('turn_completed', 'safe')])
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'late'}]))
        self.assertEqual(self.tailer.poll(), [])

    def test_bounded_poll_and_oversize_line_fail_closed(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        while not self.tailer.poll(max_bytes=7):
            pass
        self.append(entry('response_item', type='message', role='assistant', phase='analysis',
                          content=[{'type': 'output_text', 'text': 'private' * 12000}]))
        self.assertEqual(self.tailer.poll(), [])
        self.assertTrue(self.tailer.snapshot().projection_gap)
        self.assertEqual(self.tailer.snapshot().pending_bytes, 0)
        self.append(entry('event_msg', type='task_complete', turn_id=TURN))
        complete = self.tailer.poll()
        self.assertEqual([e.kind for e in complete], ['turn_completed'])
        self.assertFalse(complete[0].projection_complete)

    def test_arm_next_binds_once_and_never_rebinds(self):
        self.tailer.close()
        self.tailer = RolloutTailer(self.home, self.path, THREAD, arm_next=True)
        self.append(entry('event_msg', type='task_complete', turn_id='prior'))
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'prior'}]))
        self.assertEqual(self.tailer.poll(), [])
        self.assertIsNone(self.tailer.turn_id)
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.assertEqual([e.kind for e in self.tailer.poll()], ['turn_started'])
        self.assertEqual(self.tailer.turn_id, TURN)
        self.append(entry('event_msg', type='task_started', turn_id='another'))
        with self.assertRaises(RolloutUnsafe):
            self.tailer.poll()
        self.assertEqual(self.tailer.turn_id, TURN)

    def test_oversized_record_before_arm_is_uncertain(self):
        self.tailer.close()
        self.tailer = RolloutTailer(self.home, self.path, THREAD, arm_next=True)
        self.append(b'x' * (RolloutTailer.MAX_LINE_BYTES + 1))
        with self.assertRaises(RolloutUnsafe):
            self.tailer.poll()

    def test_oversized_final_is_not_imported_as_complete_reply(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.assertEqual([e.kind for e in self.tailer.poll()], ['turn_started'])
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'X' * 70000}]))
        self.append(entry('event_msg', type='task_complete', turn_id=TURN))
        events = self.tailer.poll()
        self.assertEqual([e.kind for e in events], ['turn_completed'])
        self.assertFalse(events[0].projection_complete)

    def test_phase_null_only_task_complete_supplies_authoritative_final(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.append(entry('response_item', type='message', role='assistant', phase=None,
                          content=[{'type': 'output_text', 'text': 'unattributed draft'}]))
        self.append(entry('event_msg', type='task_complete', turn_id='wrong',
                          last_agent_message='wrong answer'))
        self.assertEqual([e.kind for e in self.tailer.poll()], ['turn_started'])
        self.append(entry('event_msg', type='task_complete', turn_id=TURN,
                          last_agent_message='FAKE_DONE'))
        events = self.tailer.poll()
        self.assertEqual([(e.kind, e.text) for e in events], [('turn_completed', 'FAKE_DONE')])
        self.assertTrue(events[0].projection_complete)

    def test_large_final_fallback_is_not_truncated_or_complete(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.tailer.poll()
        self.append(entry('event_msg', type='task_complete', turn_id=TURN,
                          last_agent_message='X' * (RolloutTailer.MAX_TEXT_CHARS + 1)))
        events = self.tailer.poll()
        self.assertEqual([e.kind for e in events], ['turn_completed'])
        self.assertIsNone(events[0].text)
        self.assertFalse(events[0].projection_complete)

    def test_large_explicit_final_marks_projection_incomplete(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.tailer.poll()
        self.append(entry('response_item', type='message', role='assistant', phase='final',
                          content=[{'type': 'output_text', 'text': 'X' * (RolloutTailer.MAX_TEXT_CHARS + 1)}]))
        self.append(entry('event_msg', type='task_complete', turn_id=TURN,
                          last_agent_message='short fallback'))
        events = self.tailer.poll()
        self.assertEqual([e.kind for e in events], ['turn_completed'])
        self.assertEqual(events[0].text, 'short fallback')
        self.assertFalse(events[0].projection_complete)

    def test_arm_mode_requires_explicit_choice(self):
        with self.assertRaises(ValueError):
            RolloutTailer(self.home, self.path, THREAD)
        with self.assertRaises(ValueError):
            RolloutTailer(self.home, self.path, THREAD, TURN, arm_next=True)

    def test_truncation_replacement_and_prefix_rewrite_fail_closed(self):
        self.append(entry('event_msg', type='task_started', turn_id=TURN))
        self.tailer.poll()
        with self.path.open('wb') as stream:
            stream.write(b'')
        with self.assertRaises(RolloutUnsafe):
            self.tailer.poll()

        path2 = self.home / 'sessions' / 'second.jsonl'
        path2.write_bytes(b'')
        second = RolloutTailer(self.home, path2, THREAD, TURN)
        try:
            replacement = path2.with_suffix('.replacement')
            replacement.write_bytes(b'')
            os.replace(replacement, path2)
            with self.assertRaises(RolloutUnsafe):
                second.poll()
        finally:
            second.close()

        path3 = self.home / 'sessions' / 'third.jsonl'
        path3.write_bytes(b'old\n')
        third = RolloutTailer(self.home, path3, THREAD, TURN)
        try:
            path3.write_bytes(b'new\n')
            with self.assertRaises(RolloutUnsafe):
                third.poll()
        finally:
            third.close()

    def test_reject_symlink_and_path_escape(self):
        target = self.home / 'sessions' / 'target.jsonl'
        target.write_bytes(b'')
        link = self.home / 'sessions' / 'link.jsonl'
        link.symlink_to(target)
        with self.assertRaises(RolloutUnsafe):
            RolloutTailer(self.home, link, THREAD, TURN)
        with self.assertRaises(RolloutUnsafe):
            RolloutTailer(self.home, self.home / 'sessions' / '..' / 'target.jsonl', THREAD, TURN)
        with self.assertRaises(RolloutUnsafe):
            RolloutTailer(self.home, self.home / 'outside.jsonl', THREAD, TURN)


class ContinuousObserverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve()
        (self.home / 'sessions').mkdir()
        self.path = self.home / 'sessions' / 'new.jsonl'
        self.path.write_bytes(entry('session_meta', id=THREAD, session_id=THREAD))

    def tearDown(self):
        self.temp.cleanup()

    def append(self, data):
        with self.path.open('ab') as stream:
            stream.write(data)

    @staticmethod
    def user(turn, text, kinds=None):
        return entry('response_item', type='message', role='user',
                     content=[{'type': 'input_text', 'text': text}],
                     internal_chat_message_metadata_passthrough={
                         'turn_id': turn, 'content_item_kinds': kinds or ['user.text']})

    def test_new_file_header_and_two_native_turns(self):
        observer = RolloutObserver(self.home, self.path, THREAD, from_start=True)
        try:
            self.append(entry('event_msg', type='task_started', turn_id='one'))
            self.append(self.user('one', '<environment_context>fake</environment_context>',
                                  ['environments.environment_context']))
            self.append(self.user('wrong', 'wrong turn'))
            self.append(self.user('one', 'terminal 原文'))
            self.append(entry('event_msg', type='task_complete', turn_id='one', last_agent_message='answer one'))
            self.append(entry('event_msg', type='task_started', turn_id='two'))
            self.append(self.user('two', 'second raw input'))
            self.append(entry('event_msg', type='task_complete', turn_id='two', last_agent_message='answer two'))
            events = observer.poll()
            self.assertEqual([(e.kind, e.turn_id, e.text) for e in events], [
                ('turn_started', 'one', None), ('user_message', 'one', 'terminal 原文'),
                ('turn_completed', 'one', 'answer one'), ('turn_started', 'two', None),
                ('user_message', 'two', 'second raw input'), ('turn_completed', 'two', 'answer two')])
            self.assertEqual(observer.poll(), [])
        finally:
            observer.close()

    def test_default_eof_avoids_replay_on_restart(self):
        self.append(entry('event_msg', type='task_started', turn_id='old'))
        self.append(self.user('old', 'old input'))
        self.append(entry('event_msg', type='task_complete', turn_id='old', last_agent_message='old answer'))
        observer = RolloutObserver(self.home, self.path, THREAD)
        try:
            self.assertEqual(observer.poll(), [])
            self.append(entry('event_msg', type='task_started', turn_id='new'))
            self.append(self.user('new', 'new input'))
            self.assertEqual([e.kind for e in observer.poll()], ['turn_started', 'user_message'])
        finally:
            observer.close()

    def test_header_mismatch_and_second_start_during_active_fail_closed(self):
        wrong = self.home / 'sessions' / 'wrong.jsonl'
        wrong.write_bytes(entry('session_meta', id='other'))
        observer = RolloutObserver(self.home, wrong, THREAD, from_start=True)
        try:
            with self.assertRaises(RolloutUnsafe):
                observer.poll()
        finally:
            observer.close()
        observer = RolloutObserver(self.home, self.path, THREAD, from_start=True)
        try:
            self.append(entry('event_msg', type='task_started', turn_id='one'))
            self.append(entry('event_msg', type='task_started', turn_id='two'))
            with self.assertRaises(RolloutUnsafe):
                observer.poll()
        finally:
            observer.close()

    def test_oversized_record_between_turns_cannot_hide_next_start(self):
        observer = RolloutObserver(self.home, self.path, THREAD, from_start=True)
        try:
            self.append(entry('event_msg', type='task_started', turn_id='one'))
            self.append(entry('event_msg', type='task_complete', turn_id='one'))
            self.assertEqual([e.kind for e in observer.poll()], ['turn_started', 'turn_completed'])
            self.append(b'X' * (RolloutObserver.MAX_LINE_BYTES + 1))
            with self.assertRaises(RolloutUnsafe):
                observer.poll()
        finally:
            observer.close()


if __name__ == '__main__':
    unittest.main()
