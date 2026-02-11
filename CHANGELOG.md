# Changelog

## 0.2.0 - 2026-02-11

### Breaking Changes

- Removed `limit_with`. Use `limit_method` with the `registry:` option instead.
  - Before: `limit_with :execute, registry: :external_api`
  - After: `limit_method :execute, registry: :external_api`
- `limit_method` now raises `ArgumentError` when called without `registry:` or `rate:`.
- `limit_method` raises `ArgumentError` when `registry:` is combined with any other option (`rate:`, `interval:`, `check_interval:`, or `max_wait_time:`).
- Removed `key_prefix` from `limit_method`. Registry-based limits derive their key automatically.
- Removed `key_prefix` from `register_limit`. Registry keys are now always derived internally from the registry name.

### Added

- `register_temporary_limit(name, remaining:, reset:)` — dynamically override a registered limit with a fixed-window counter and TTL, based on API response headers.
- Override-exhausted requests raise `RateLimitError` immediately when the remaining TTL exceeds `max_wait_time`, instead of polling.
- Input validation for `register_temporary_limit` — returns `false` for nil, negative, zero, or non-numeric values.

## 0.1.0 - 2026-02-04

- Initial release of Hanikamu::RateLimit.
