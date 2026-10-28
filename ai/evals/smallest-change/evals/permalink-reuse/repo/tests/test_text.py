import unittest

from blog.text import slugify, truncate


class SlugifyTest(unittest.TestCase):
    def test_lowercases_and_hyphenates(self):
        self.assertEqual(slugify("Hello World"), "hello-world")


class TruncateTest(unittest.TestCase):
    def test_leaves_short_text_alone(self):
        self.assertEqual(truncate("short", 10), "short")


if __name__ == "__main__":
    unittest.main()
