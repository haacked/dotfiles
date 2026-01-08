### Read Before You Write

Before implementing functionality that operates on a type:

1. Read the struct definition and check its derives (`Deserialize`, `Serialize`, `Clone`, `Default`, etc.)
2. If a derive provides what you need, use it - don't reimplement manually
3. If writing >10 lines for parsing/serialization, stop and check the derives

**Common derive usage:**

| Struct has... | Use this | Not this |
|---------------|----------|----------|
| `#[derive(Deserialize)]` | `serde_json::from_value()` | Manual `.get("field")` chains |
| `#[derive(Serialize)]` | `serde_json::to_value()` | Manual JSON building |
| `#[derive(Clone)]` | `.clone()` | Manual field-by-field copy |
| `#[derive(Default)]` | `Default::default()` | Manual zero-initialization |

### Error Handling

- Use `Result<T, E>` for recoverable errors, `?` for propagation
- Prefer `anyhow` or `thiserror` over custom error types
- Use `expect("reason")` over `unwrap()` when you must unwrap
- Never `unwrap()` on user input or external data

### Ownership & Borrowing

- Use `&str` for string parameters, `String` only when you need ownership
- Prefer borrowing over `Clone` when possible
- If fighting the borrow checker, redesign the data flow

### Async Code

- Never block in async functions - use `spawn_blocking` for CPU work
- Don't hold locks across `.await` points (deadlock risk)
- Always handle cancellation with `tokio::select!`

### Guard Patterns (RAII)

- **Log/metric guards that auto-emit on drop**: Never call `emit()` through a mutable reference like `guard.log_mut().emit()`. This emits but doesn't set the guard's `emitted` flag, causing double emission on drop.
- **Correct patterns**:
  - Set fields and let the guard emit on drop
  - Consume the guard with `guard.emit()` or `guard.into_inner()`

### Error Code Consistency

- Use the error type's `error_code()` method instead of hardcoding strings
- Keeps logs, metrics, and API responses consistent

### String Operations

- **Efficient truncation**: Use `s.char_indices().nth(max_chars)` to find the byte position in one pass, then slice. Avoid counting characters twice:

```rust
// Good - O(max_chars)
match s.char_indices().nth(max_chars) {
    None => Cow::Borrowed(s),
    Some((idx, _)) => Cow::Owned(s[..idx].to_string()),
}

// Bad - O(2n)
if s.chars().count() > max { s.chars().take(max).collect() }
```

### Request Pipeline Awareness

- Before adding validation/truncation, check if the request parsing layer already handles it
- Example: distinct_id may already be truncated at parse time

### Filtering with Dependencies

- When optimizing by filtering to a subset (e.g., `flag_keys`), ensure dependencies from the full graph are included in the analysis
- A flag might not be in the filter set but still get evaluated as a dependency

### Quality Checklist

Before committing Rust code:

1. `cargo fmt`
2. `cargo clippy --all-targets --all-features -- -D warnings`
3. `cargo shear` - investigate any warnings
4. `cargo test`
