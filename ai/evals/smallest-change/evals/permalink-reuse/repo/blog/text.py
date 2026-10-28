import re
import unicodedata


def slugify(value):
    """Lowercases `value`, drops accents and punctuation, and joins the words with hyphens."""
    ascii_text = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def truncate(value, length):
    """Cuts `value` to at most `length` characters at a word boundary and adds an ellipsis when it cuts."""
    if len(value) <= length:
        return value
    return value[: length - 1].rsplit(" ", 1)[0] + "…"
