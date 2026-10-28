from shop.money import parse_amount


def refund_amount(order_total, amount_text):
    """Returns the amount to refund. Raises ValueError when it exceeds the order total."""
    amount = parse_amount(amount_text)
    if amount > order_total:
        raise ValueError("refund exceeds order total")
    return amount
