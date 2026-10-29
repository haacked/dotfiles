import unittest
from unittest import mock

from app.webhooks import DeliveryError, deliver

URL = "https://example.test/hook"


@mock.patch("time.sleep")
class DeliverRetryTest(unittest.TestCase):
    def test_retries_until_the_endpoint_accepts(self, _sleep):
        post = mock.Mock(side_effect=[500, 503, 200])

        deliver(URL, {}, post)

        self.assertEqual(post.call_count, 3)

    def test_gives_up_after_three_attempts(self, _sleep):
        post = mock.Mock(return_value=500)

        with self.assertRaises(DeliveryError):
            deliver(URL, {}, post)

        self.assertEqual(post.call_count, 3)

    def test_sends_once_when_the_first_attempt_succeeds(self, _sleep):
        post = mock.Mock(return_value=200)

        deliver(URL, {}, post)

        post.assert_called_once()

    def test_does_not_retry_other_errors(self, _sleep):
        post = mock.Mock(side_effect=ConnectionResetError())

        with self.assertRaises(ConnectionResetError):
            deliver(URL, {}, post)

        post.assert_called_once()


if __name__ == "__main__":
    unittest.main()
