"""Synthetic tmux command tests; no real image, model, or tmux session."""
import tempfile
import unittest
from pathlib import Path

from tmux_images import END, START, paste_image, paste_text, submit


class FakePane:
    pane_id = '%7'

    def __init__(self):
        self.calls = []
        self.fail_paste = False

    def _require_attached(self):
        self.calls.append(('verify',))

    def _run(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        if self.fail_paste and args[0] == 'paste-buffer':
            raise RuntimeError('unknown delivery')

    def send_special(self, key):
        self.calls.append(('key', key))


class ImagePasteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.image = self.root / 'synthetic.png'
        self.image.write_bytes(b'\x89PNG\r\n\x1a\n' + b'synthetic-only')
        self.pane = FakePane()

    def tearDown(self):
        self.temp.cleanup()

    def test_explicit_brackets_and_single_enter_for_multiline_and_image(self):
        submit(self.pane, text='line one\nline two', image_paths=[self.image], allowed_root=self.root)
        loaded = [call for call in self.pane.calls if isinstance(call[0], tuple) and call[0][0] == 'load-buffer']
        self.assertEqual([call[1]['input'] for call in loaded],
                         [START + str(self.image) + END, START + 'line one\nline two' + END])
        pasted = [call[0] for call in self.pane.calls if isinstance(call[0], tuple) and call[0][0] == 'paste-buffer']
        self.assertEqual(len(pasted), 2)
        self.assertTrue(all('-dr' in command and '-p' not in command for command in pasted))
        self.assertEqual(self.pane.calls.count(('key', 'Enter')), 1)

    def test_no_unvalidated_path_or_control_reaches_pane(self):
        outside = self.root.parent / 'outside-image.png'
        with self.assertRaises(ValueError):
            submit(self.pane, image_paths=[outside], allowed_root=self.root)
        with self.assertRaises(ValueError):
            paste_text(self.pane, 'a\x1b[201~')
        link = self.root / 'link.png'
        link.symlink_to(self.image)
        with self.assertRaises(ValueError):
            paste_image(self.pane, link, allowed_root=self.root)
        self.assertEqual(self.pane.calls, [])

    def test_failure_deletes_one_use_buffer_without_enter(self):
        self.pane.fail_paste = True
        with self.assertRaises(RuntimeError):
            submit(self.pane, image_paths=[self.image], allowed_root=self.root)
        self.assertTrue(any(isinstance(call[0], tuple) and call[0][0] == 'delete-buffer'
                            for call in self.pane.calls))
        self.assertNotIn(('key', 'Enter'), self.pane.calls)


if __name__ == '__main__':
    unittest.main()
