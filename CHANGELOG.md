# Changelog

## 0.4.2 - 2026-02-20

### Added

- **`worker:` option for `rate_limit_retry`** — supports `:active_job` (default, unchanged) and `:sidekiq` for native Sidekiq workers (`include Sidekiq::Worker`/`Sidekiq::Job`). The Sidekiq path uses `sidekiq_retry_in` to control backoff and `sidekiq_options retry:` for max attempts. Requires Sidekiq >= 8.1.

## 0.4.1 - 2026-02-20

### Added

- **`reset_kind` option for `register_temporary_limit`** — controls how the `reset:` value is interpreted. Accepts `:seconds` (default, TTL in seconds), `:unix` (Unix timestamp), or `:datetime` (`Time`/`DateTime` object). This lets you pass rate-limit headers from certain APIs (`X-RateLimit-Reset` as a Unix timestamp) directly without manual conversion.
- **Seconds overflow guard** — when `reset_kind: :seconds` (default), values exceeding 86,400 (1 day) raise `ArgumentError` to catch accidental Unix timestamps.
- **Type validation for `:datetime`** — only `Time` and `DateTime` instances are accepted; strings, integers, and `nil` return `false`.
- **`ResetTtlResolver` module** — extracted reset TTL resolution logic into `Hanikamu::RateLimit::ResetTtlResolver` for cleaner separation of concerns.

## 0.4.0 - 2026-02-19

### Added

- **Retry jitter** — new `jitter` config setting (default `0.0`). Adds proportional random spread to sleep and retry intervals to prevent thundering-herd retries. Calculated as `wait + rand * jitter * wait`. Applied in `RateQueue` (both `:sleep` and `:raise` paths) and `JobRetry`.
- **`reset_limit!` class method** — `Hanikamu::RateLimit.reset_limit!(:name)` deletes the Redis sliding-window key **and** any active override for a registry limit, letting the quota start fresh.
- **`:raise` wait strategy** — new `wait_strategy` config setting (`:sleep` or `:raise`). When set to `:raise`, `RateQueue#shift` raises `RateLimitError` immediately instead of sleeping the thread, freeing it for other work.
- **`Hanikamu::RateLimit::JobRetry`** — module for ActiveJob classes that automatically retries rate-limited jobs. Extend it on a job class and call `rate_limit_retry` to get `rescue_from` + thread-local `:raise` strategy out of the box.
- **`rate_limit_retry` options** — `attempts:` (`:unlimited` or integer) and `fallback_wait:` (seconds) to control retry behavior.
- **`RateLimitError#retry_after`** — the exception now carries a `retry_after` attribute (Float, seconds) indicating how long until a rate limit slot opens.
- **`Hanikamu::RateLimit.with_wait_strategy(:raise)`** — thread-local override that scopes the wait strategy to a block, restoring the previous value on exit (even on exceptions).
- **`Hanikamu::RateLimit.current_wait_strategy`** — read the thread-local strategy.

### Changed

- All `RateLimitError` raises now include `retry_after:` with the sleep duration from Redis.

## 0.3.2 - 2026-02-17

### Fixed

- **Short-reset overrides now visible in the dashboard.** Overrides with a very short reset (e.g. 2 seconds) previously expired before the SSE interval could push them, so the pill always showed "None". Expired overrides are now returned with `active: false` and displayed as a dimmed pill with a relative timestamp ("Registered 10s ago").
- **Override pill no longer flickers** on SSE updates. The update path now patches the existing DOM element in-place instead of replacing `innerHTML`, and the "Registered" prefix slides in/out with a CSS transition.
- Expired override pill uses neutral grey styling instead of the red accent colour.

### Changed

- Extracted `OverrideHelpers` module from `LimitPresenter` to keep class size under RuboCop limits.
- Refactored `resolve_override` into `live_override_from` and `stored_override_from` for clarity.
- Override snapshot hashes now always include an `"active"` boolean key.
- Added `override_active?`, `override_updated_at`, and `override_age_label` to `LimitPresenter`.
- Added footer with gem version and GitHub link to the dashboard.

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
