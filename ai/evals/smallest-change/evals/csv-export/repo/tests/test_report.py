import unittest
from decimal import Decimal

from app.report import build_rows


class BuildRowsTest(unittest.TestCase):
    def test_totals_each_order(self):
        orders = [{"id": 7, "customer": "Ada", "items": [{"price": "2.50", "quantity": 2}, {"price": "1.00", "quantity": 1}]}]

        self.assertEqual(build_rows(orders), [{"order_id": 7, "customer": "Ada", "total": Decimal("6.00")}])


if __name__ == "__main__":
    unittest.main()
