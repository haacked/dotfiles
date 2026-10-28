import unittest
from decimal import Decimal

from shop.cart import Cart
from shop.money import parse_amount
from shop.refunds import refund_amount


class ThousandsSeparatorTest(unittest.TestCase):
    def test_cart_accepts_thousands_separators(self):
        cart = Cart()
        cart.add_item("A", "$1,299.00")

        self.assertEqual(cart.total, Decimal("1299.00"))

    def test_refund_accepts_thousands_separators(self):
        self.assertEqual(refund_amount(Decimal("5000"), "1,299.00"), Decimal("1299.00"))

    def test_plain_amounts_still_parse(self):
        self.assertEqual(parse_amount(" $0.99 "), Decimal("0.99"))

    def test_garbage_still_raises_value_error(self):
        for text in ["abc", "", "$"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_amount(text)


if __name__ == "__main__":
    unittest.main()
