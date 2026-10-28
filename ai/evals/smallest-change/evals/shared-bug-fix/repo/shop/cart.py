from decimal import Decimal

from shop.money import parse_amount


class Cart:
    def __init__(self):
        self.items = []

    def add_item(self, sku, price_text):
        self.items.append((sku, parse_amount(price_text)))

    @property
    def total(self):
        return sum((price for _, price in self.items), Decimal("0"))
