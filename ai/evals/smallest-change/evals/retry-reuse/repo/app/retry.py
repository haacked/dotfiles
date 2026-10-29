import time


def with_retries(fn, *, attempts, retry_on, delay=0.5):
    """Calls fn() until it returns, making at most `attempts` calls.

    Retries only the exception types in `retry_on`, waiting `delay` seconds and then twice as long before each retry. Raises the last exception when every attempt fails.
    """
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except retry_on:
            if attempt == attempts:
                raise
            time.sleep(delay * 2 ** (attempt - 1))
