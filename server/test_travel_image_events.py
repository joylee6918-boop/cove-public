"""Synthetic completion payloads only; no image generation or external IO."""
import base64
import unittest
from unittest.mock import patch
from storage import APIError
from travel_image_events import decode_completed_image

# Explicit synthetic 1x1 PNG fixture; never sent to production.
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1cAAAAASUVORK5CYII=')


class NativeImageTests(unittest.TestCase):
    def setUp(self):
        self.item={'type':'imageGeneration','id':'image-1','status':'completed','result':base64.b64encode(PNG).decode()}

    def invalid(self,expected_status,**overrides):
        with self.assertRaises(APIError) as caught:decode_completed_image(dict(self.item,**overrides))
        self.assertEqual(caught.exception.status,expected_status)

    def test_exact_native_bytes_mime_and_stable_safe_filename(self):
        first=decode_completed_image(self.item)
        self.assertEqual(first[1: ],('image/png',PNG))
        self.assertEqual(decode_completed_image(self.item),first)
        name,_,_=decode_completed_image(dict(self.item,id='../../untrusted/name'))
        self.assertNotIn('/',name)
        self.assertTrue(name.endswith('.png'))

    def test_paths_urls_and_data_uri_never_opened(self):
        for raw in ('/etc/passwd','http://127.0.0.1/private','https://example.test/image.png','data:image/png;base64,aGVsbG8=','%%%'):
            with self.subTest(raw=raw),patch('builtins.open',side_effect=AssertionError('no file IO')):
                with self.assertRaises(APIError):decode_completed_image(dict(self.item,result=raw,savedPath='/etc/passwd'))

    def test_empty_result_does_not_fallback_to_saved_path(self):
        self.invalid(503,result='',savedPath='/tmp/image.png')
        self.invalid(503,result=None)

    def test_failure_or_noncompleted_never_success(self):
        self.invalid(503,status='failed');self.invalid(503,status='in_progress')
        self.invalid(503,failure={'message':'failed'})
        self.assertIsNotNone(decode_completed_image(dict(self.item,failure=None)))

    def test_unsupported_bytes_and_size_bounds(self):
        self.invalid(400,result=base64.b64encode(b'<svg/>').decode())
        with patch('travel_image_events.MAX_ATTACHMENT',5):self.invalid(413)
        for value in ('',None,[], 'x'*601):self.invalid(400,id=value)

    def test_unrelated_items_ignored(self):
        for item in (None,[],{},dict(self.item,type='agentMessage')):
            self.assertIsNone(decode_completed_image(item))


if __name__=='__main__':unittest.main()
