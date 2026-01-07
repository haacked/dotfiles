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

### Django ORM

- Use `select_related()` for ForeignKey/OneToOne
- Use `prefetch_related()` for ManyToMany/reverse FK
- Use `.count()` not `len(queryset)`
- Use `bulk_create`/`bulk_update` for batch operations
- Filter in database, not Python

### Error Handling

- Use `get_object_or_404()` in views
- Handle `DoesNotExist` explicitly
- Use `@transaction.atomic` for multi-step operations
- Don't catch broad exceptions without logging

### Security

- Validate all user input (use Django forms)
- Use ORM - avoid raw SQL
- Check permissions before data access
- Don't roll custom auth - use Django's

### Quality Checklist

Before committing Python code:
1. `ruff check` and `ruff format`
2. `mypy` (if configured)
3. `pytest` for tests
