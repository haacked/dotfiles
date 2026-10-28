import unittest
from datetime import date

from blog.models import Post


def permalink(title, published=date(2026, 3, 9)):
    return Post(title=title, published=published, body="").permalink


class PermalinkTest(unittest.TestCase):
    def test_builds_year_month_slug_path(self):
        self.assertEqual(permalink("Hello World"), "/blog/2026/03/hello-world/")

    def test_drops_accents_and_punctuation(self):
        self.assertEqual(permalink("Café déjà vu!"), "/blog/2026/03/cafe-deja-vu/")

    def test_collapses_repeated_separators(self):
        self.assertEqual(permalink("  Rust -- & Go  "), "/blog/2026/03/rust-go/")

    def test_pads_single_digit_months(self):
        self.assertEqual(permalink("New Year", date(2027, 1, 1)), "/blog/2027/01/new-year/")


if __name__ == "__main__":
    unittest.main()
