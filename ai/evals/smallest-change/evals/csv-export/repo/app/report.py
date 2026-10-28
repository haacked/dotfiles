from decimal import Decimal

COLUMNS = ("order_id", "customer", "total")


def build_rows(orders):
    """Returns one row per order, in the column order of COLUMNS."""
    rows = []
    for order in orders:
        total = sum((Decimal(item["price"]) * item["quantity"] for item in order["items"]), Decimal("0"))
        rows.append({"order_id": order["id"], "customer": order["customer"], "total": total})
    return rows
