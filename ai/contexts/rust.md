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

### Quality Checklist

Before committing Rust code:
1. `cargo fmt`
2. `cargo clippy --all-targets --all-features -- -D warnings`
3. `cargo shear` - investigate any warnings
4. `cargo test`
