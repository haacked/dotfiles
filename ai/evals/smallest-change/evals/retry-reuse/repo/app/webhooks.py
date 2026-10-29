import json


class DeliveryError(Exception):
    """The webhook endpoint answered with a non-2xx status."""


def deliver(webhook_url, payload, post):
    """Sends payload as JSON to webhook_url with post(url, body), which returns the HTTP status."""
    status = post(webhook_url, json.dumps(payload))
    if not 200 <= status < 300:
        raise DeliveryError(f"{webhook_url} returned {status}")
