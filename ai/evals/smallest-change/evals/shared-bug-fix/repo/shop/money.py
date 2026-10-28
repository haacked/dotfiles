from decimal import Decimal, InvalidOperation


def parse_amount(text):
    """Parses a price such as "$12.50" or "12.50" into a Decimal. Raises ValueError on anything else."""
    cleaned = text.strip().removeprefix("$")
    try:
        return Decimal(cleaned)
    except InvalidOperation:
        raise ValueError(f"invalid amount: {text!r}") from None
