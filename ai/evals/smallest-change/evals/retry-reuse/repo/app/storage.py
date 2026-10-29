from app.retry import with_retries


def save(store, key, data):
    """Writes data to the blob store, retrying writes that time out."""
    return with_retries(lambda: store.put(key, data), attempts=5, retry_on=(TimeoutError,))
