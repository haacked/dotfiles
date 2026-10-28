import unittest
from decimal import Decimal

from shop.cart import Cart
from shop.refunds import refund_amount


class CartTest(unittest.TestCase):
    def test_totals_items(self):
        cart = Cart()
        cart.add_item("A", "$12.50")
        cart.add_item("B", "0.50")

        self.assertEqual(cart.total, Decimal("13.00"))


class RefundTest(unittest.TestCase):
    def test_refuses_more_than_the_order_total(self):
        with self.assertRaises(ValueError):
            refund_amount(Decimal("5"), "$6")


if __name__ == "__main__":
    unittest.main()
