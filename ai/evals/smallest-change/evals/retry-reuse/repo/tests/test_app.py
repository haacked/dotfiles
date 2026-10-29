import unittest
from unittest import mock

from app.storage import save
from app.webhooks import DeliveryError, deliver


class SaveTest(unittest.TestCase):
    @mock.patch("time.sleep")
    def test_retries_timeouts(self, _sleep):
        store = mock.Mock()
        store.put.side_effect = [TimeoutError(), "ok"]

        self.assertEqual(save(store, "k", b"data"), "ok")
        self.assertEqual(store.put.call_count, 2)


class DeliverTest(unittest.TestCase):
    def test_posts_the_payload_as_json(self):
        post = mock.Mock(return_value=204)

        deliver("https://example.test/hook", {"event": "signup"}, post)

        post.assert_called_once_with("https://example.test/hook", '{"event": "signup"}')

    def test_raises_on_an_error_status(self):
        with self.assertRaises(DeliveryError):
            deliver("https://example.test/hook", {}, mock.Mock(return_value=500))


if __name__ == "__main__":
    unittest.main()
