<!-- claudeconfig:bundled -->
# Rust Conventions

## Tooling
- Always use standard formatter (`cargo fmt`) and linter (`cargo clippy`).
- Target the current stable compiler version.

## Dependencies
- Keep external dependencies minimal.
- Use `clap` (with derive feature) for CLI arguments.
- Use `serde` for serialization/deserialisation.
- Use `anyhow` for application-level error handling, and `thiserror` for library boundaries.
- Avoid heavy runtime frameworks (like `tokio`) unless asynchronous operations are explicitly required.

## Error Handling
- Avoid `panic!`, `unwrap()`, or `expect()` in library and production code.
- If an operation can fail, return a `Result` or `Option`.
- In test code, `unwrap()` is permitted.

## Project Structure
- For applications, put core logic in a library (`src/lib.rs`) and CLI handling in the binary (`src/main.rs`).
- Unit tests go in the same file as the code under a `tests` module:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      // ...
  }
  ```
- Integration tests go in the `tests/` directory.

## Unsafe Code
- Avoid `unsafe` block unless strictly required for Wayland protocol integrations or C bindings.
- All `unsafe` blocks must be documented with a `// SAFETY:` comment explaining why the invariants are met.
