import unittest
from datetime import date

from blog.models import Post


class PostTest(unittest.TestCase):
    def test_excerpt_truncates_the_body(self):
        post = Post(title="T", published=date(2026, 1, 2), body="word " * 100)

        self.assertLessEqual(len(post.excerpt), 140)


if __name__ == "__main__":
    unittest.main()
