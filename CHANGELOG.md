# Changelog

## 0.3.1 - 2026-02-17

### Fixed

- `register_temporary_limit` now unwraps array values for `remaining:` and `reset:` (e.g. `["99"]` from HTTParty's `headers.to_h`). Previously these were silently rejected as non-numeric.

## 0.3.0 - 2026-02-17

### Added

- **UI dashboard** — mountable Rails engine (`Hanikamu::RateLimit::UI::Engine`) with real-time Server-Sent Events (SSE) streaming.
  - Summary cards — limits tracked, window size, bucket size, timestamp.
  - Redis info cards — version, memory usage, peak memory, connected clients. Updated live via SSE.
  - Per-limit cards with current rate, hits/sec, blocked/sec stats.
  - Rolling counters for 5 minutes, 24 hours, and all-time totals (allowed and blocked).
  - 24-hour chart with allowed requests, limit line, and blocked-period red background bands.
  - 5-minute chart with interval-aware bucket aggregation and blocked-period highlighting.
  - Override pill showing remaining requests and reset time when a dynamic override is active.
  - Metrics enabled/disabled badge per limit card.
- **`ui_auth`** — deny-by-default authentication hook for the dashboard. All endpoints return `403 Forbidden` until configured.
- **`ui_max_sse_connections`** — configurable limit on concurrent SSE connections (default: 10). Returns `503 Service Unavailable` when exhausted.
- **Per-limit `metrics:` option** on `register_limit` to override global `metrics_enabled`.
- **Per-method `metrics:` option** on inline `limit_method` calls (cannot be combined with `registry:`).
- Metrics time-series collection for allowed/blocked counts and override status with TTLs on all keys.
- Pipelined Redis reads for efficient dashboard snapshots.
- Dashboard payload caching (1-second TTL) and Redis info caching (10-second TTL).
- `beforeunload` SSE cleanup — browser closes the EventSource before page reload to free server threads promptly.
- SSE connections auto-close after 1 minute; the browser reconnects transparently.
- XSS prevention with `escapeHtml` and `safeNum` helpers in dashboard JavaScript.
- Chart.js 4.4.8 loaded with Subresource Integrity (SRI) pinning.
- System font stack (no external font requests).

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
