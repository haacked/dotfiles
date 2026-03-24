### Import Organization

- Imports at top of file (unless circular reference)
- Group: standard library → third-party → local (blank line between)
- Use absolute imports, avoid `from module import *`
- For type-only imports with circular deps:

```python
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from .models import User
```

### Type Hints

- Add type hints to all function signatures
- Use `Optional[T]` for nullable, avoid bare `None` returns
- Use `TypedDict` for structured dicts, not `dict[str, Any]`
- Run `mypy` to catch type errors

### Dictionary Access Patterns

- Use `dict["key"]` for required fields (fails fast with `KeyError` if data is malformed)
- Use `dict.get("key")` only for genuinely optional fields where absence is valid
- When building lookup dicts, use direct access for the key field:

```python
# Good - fails fast if "id" is missing
flags_by_id = {flag["id"]: flag for flag in flags}

# Bad - silently maps None as a key, causing subtle bugs later
flags_by_id = {flag.get("id"): flag for flag in flags}
```

### Async/Await Patterns

- Never forget `await` on coroutines — a bare `fetch_data()` without `await` returns a coroutine object, not the result
- Don't use blocking operations (file I/O, `time.sleep()`) in async functions — use `asyncio.sleep()`, `aiofiles`, or `sync_to_async`
- Handle floating promises: always `await` or explicitly discard with a comment

### Error Handling

- Don't catch broad exceptions without logging
- Handle specific exception types explicitly
- Use context managers (`with` statements) for resource cleanup
- Raise exceptions early, catch them late

### Security

- Validate all user input before processing
- Use parameterized queries — avoid string-formatted SQL
- Check permissions before data access
- Don't roll custom auth — use framework-provided auth

### Timing and Duration Measurement

- Use `time.monotonic()` for measuring durations, not `time.time()`
- `monotonic()` is immune to system clock changes (NTP, DST, manual adjustments)
- `time.time()` can jump backward or forward unexpectedly

```python
# Good
start = time.monotonic()
do_work()
elapsed = time.monotonic() - start

# Bad - can give negative durations if clock adjusts
start = time.time()
do_work()
elapsed = time.time() - start
```

### Quality Checklist

Before committing Python code:

1. `ruff check` and `ruff format`
2. `mypy` (if configured)
3. `pytest` for tests
