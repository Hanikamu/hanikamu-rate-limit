# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting with a sliding window algorithm. Works across processes and threads by coordinating through Redis.

## Table of Contents

1. [Why Hanikamu::RateLimit?](#why-hanikamuratelimit)
2. [Quick Start](#quick-start)
3. [Configuration](#configuration)
4. [Usage](#usage)
   - [Inline limits](#inline-limits)
   - [Registry limits](#registry-limits)
   - [Dynamic overrides](#dynamic-overrides)
   - [Class methods](#class-methods)
   - [Callbacks](#callbacks)
   - [Metrics per method](#metrics-per-method)
5. [Background Jobs (ActiveJob)](#background-jobs-activejob)
6. [UI Dashboard](#ui-dashboard)
7. [Error Handling](#error-handling)
8. [Testing](#testing)
9. [Development](#development)
10. [License](#license)

## Why Hanikamu::RateLimit?

You run 40 Sidekiq workers that all hit the same external API capped at 20 requests per second. Without coordination they burst and trigger throttling. With a shared limit every worker routes through the same Redis-backed window, keeping aggregate throughput at 20 req/s across the whole fleet.

- **Distributed** — limits are enforced through Redis; multiple app instances share a single quota.
- **Sliding window** — based on the most recent interval, not fixed clock-aligned buckets.
- **Backoff with polling** — when a limit is hit the limiter sleeps in short intervals until a slot opens.
- **Bounded waiting** — callers can set a max wait time to avoid blocking indefinitely.
- **Raise strategy** — optionally raise immediately instead of sleeping, ideal for background jobs that can re-enqueue themselves.
- **Minimal surface area** — a single mixin and a compact queue implementation.

## Quick Start

Requires Ruby 4.0+.

```ruby
# Gemfile
gem "hanikamu-rate-limit", "~> 0.4"
```

```bash
bundle install
```

```ruby
# config/initializers/hanikamu_rate_limit.rb
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")
end
```

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  limit_method :execute, rate: 5, interval: 1.0

  def execute
    # work
  end
end

MyService.new.execute
```

## Configuration

```ruby
Hanikamu::RateLimit.configure do |config|
  # Required
  config.redis_url = ENV.fetch("REDIS_URL")

  # Global defaults (all optional)
  config.check_interval  = 0.25    # seconds between retries when rate limited
  config.max_wait_time   = 1.5     # max seconds to wait before raising RateLimitError
  config.wait_strategy   = :sleep  # :sleep (default) or :raise
  config.jitter          = 0.15   # proportional jitter factor (0.0 = disabled)
  config.metrics_enabled = true    # enable metrics collection for the UI dashboard

  # Named limits shared across classes
  config.register_limit(:external_api,
    rate: 5, interval: 0.5,
    check_interval: 0.5, max_wait_time: 5
  )
end
```

### Global settings

| Setting          | Default  | Description                                                           |
| ---------------- | -------- | --------------------------------------------------------------------- |
| `redis_url`      | —        | Redis connection URL (**required**).                                  |
| `check_interval` | `0.5`    | Seconds between retries when a limit is hit.                          |
| `max_wait_time`  | `2.0`    | Max seconds to wait before raising `RateLimitError`.                  |
| `wait_strategy`  | `:sleep` | `:sleep` blocks the thread; `:raise` raises immediately.              |
| `jitter`         | `0.0`    | Proportional jitter added to sleep/retry intervals (0 = off).         |
| `metrics_enabled`| `false`  | Enable metrics collection. **Must be `true`** for the UI dashboard.   |

### Registered limit options

| Option           | Required | Description                                                   |
| ---------------- | -------- | ------------------------------------------------------------- |
| `rate`           | Yes      | Max requests allowed per `interval`.                          |
| `interval`       | Yes      | Time window in seconds.                                       |
| `check_interval` | No       | Override global `check_interval` for this limit.              |
| `max_wait_time`  | No       | Override global `max_wait_time` for this limit.               |
| `metrics`        | No       | Override `metrics_enabled` for this limit (`true` / `false`). |

## Usage

### Inline limits

Pass `rate:` and `interval:` directly on the method. Optional overrides for `check_interval:`, `max_wait_time:`, and `metrics:` can be added:

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  limit_method :execute, rate: 5, interval: 1.0
  limit_method :fetch,   rate: 10, interval: 60, check_interval: 0.1, max_wait_time: 3.0, metrics: false

  def execute = "done"
  def fetch   = "fetched"
end
```

A reset method is generated automatically:

```ruby
MyService.reset_execute_limit!
```

### Registry limits

Use `registry:` to share a named limit across classes. All options come from `register_limit` — you cannot combine `registry:` with any inline options:

```ruby
class ServiceA
  extend Hanikamu::RateLimit::Mixin
  limit_method :call, registry: :external_api
  def call = "a"
end

class ServiceB
  extend Hanikamu::RateLimit::Mixin
  limit_method :call, registry: :external_api
  def call = "b"
end
```

Both classes share the same Redis-backed quota.

**Precedence** (highest to lowest):

1. Registered limit options from `register_limit`.
2. Global defaults from `configure`.

### Dynamic overrides

> Only applies to **registry-based** limits.

When an external API returns rate-limit headers you can temporarily override a registered limit:

```ruby
Hanikamu::RateLimit.register_temporary_limit(:external_api, remaining: 175, reset: 60)
```

This stores a Redis counter with `remaining` requests and a TTL of `reset` seconds. While active the fixed-window counter is used instead of the sliding window. When the TTL expires the original limit resumes automatically.

**Override-exhausted behavior** (when `remaining` reaches 0):

- If the remaining TTL exceeds `max_wait_time` → `RateLimitError` is raised immediately (no polling — the fixed-window quota won't reset until the TTL expires).
- If the remaining TTL is within `max_wait_time` → the limiter polls until the override expires and falls back to the sliding window.

Typical usage in an API client:

```ruby
class ExternalApiClient
  extend Hanikamu::RateLimit::Mixin
  limit_method :call, registry: :external_api

  def call
    response = http_client.get("/endpoint")

    if response.headers["X-RateLimit-Remaining"]
      Hanikamu::RateLimit.register_temporary_limit(
        :external_api,
        remaining: response.headers["X-RateLimit-Remaining"],
        reset:     response.headers["X-RateLimit-Reset"]
      )
    end

    response
  end
end
```

### Class methods

Apply the mixin to the singleton class:

```ruby
class MyService
  class << self
    extend Hanikamu::RateLimit::Mixin
    limit_method :call, registry: :external_api
    def call = "work"
  end
end
```

### Callbacks

An optional block is called each time the limiter sleeps:

```ruby
limit_method :execute, rate: 5, interval: 1.0 do |sleep_time|
  Rails.logger.info("Rate limited, sleeping #{sleep_time}s")
end
```

### Metrics per method

Metrics collection can be toggled at three levels (highest precedence first):

1. `metrics:` on `limit_method` (inline limits only — cannot be combined with `registry:`).
2. `metrics:` on `register_limit`.
3. `config.metrics_enabled` (global default, `false`).

## Background Jobs (ActiveJob)

### The problem

With the default `:sleep` wait strategy, `RateQueue#shift` blocks the current thread. In Sidekiq (or any threaded job runner) this means a rate-limited job occupies a thread doing nothing. If enough jobs are rate-limited simultaneously, **all threads can be blocked** and the entire process stalls.

### The solution: `:raise` strategy + `JobRetry`

Instead of sleeping, switch the wait strategy to `:raise` so the rate limiter raises `RateLimitError` immediately with a `retry_after` value. The job catches the error and re-enqueues itself with `retry_job(wait: retry_after)`, freeing the thread instantly.

`Hanikamu::RateLimit::JobRetry` is a module you `extend` on an ActiveJob class. It does two things:

1. Wraps `perform` to set a thread-local wait strategy to `:raise` for the duration of the job.
2. Adds a `rescue_from RateLimitError` handler that calls `retry_job(wait: exception.retry_after)`.

When the same service runs synchronously the default `:sleep` strategy is used — the caller blocks as expected. When it runs as an ActiveJob the thread is freed immediately.

### Usage with a simple job

```ruby
class RateLimitedJob < ApplicationJob
  extend Hanikamu::RateLimit::JobRetry
  rate_limit_retry

  def perform
    MyService.new.execute
  end
end
```

### Usage with an AsyncService concern

If you have a pattern where services can be called sync or async through a nested `::Async` class:

```ruby
module AsyncService
  extend ActiveSupport::Concern

  def self.included(base)
    base.class_eval do
      const_set(
        :Async,
        Class.new(ApplicationJob) do
          extend Hanikamu::RateLimit::JobRetry
          rate_limit_retry

          def perform(bang:, args:)
            if bang
              self.class.module_parent.call!(args)
            else
              self.class.module_parent.call(args)
            end
          end
        end
      )
    end
  end
end
```

Now every service that includes `AsyncService` gets automatic rate-limit retries when running async, while synchronous calls sleep as before.

### `rate_limit_retry` options

| Option          | Default      | Description                                                              |
| --------------- | ------------ | ------------------------------------------------------------------------ |
| `attempts`      | `:unlimited` | Max retries. `:unlimited` retries forever; an integer caps the attempts. |
| `fallback_wait` | `5`          | Seconds to wait if the exception has no `retry_after` value.             |

```ruby
extend Hanikamu::RateLimit::JobRetry
rate_limit_retry attempts: 20, fallback_wait: 10
```

### Jitter

When many jobs are rate-limited at the same time they will all retry at the same instant, causing a **thundering herd**. Setting `jitter` adds a random spread to sleep and retry intervals:

```ruby
Hanikamu::RateLimit.configure do |config|
  config.jitter = 0.15 # adds 0–15 % to each wait
end
```

The jittered wait is calculated as `wait + rand * jitter * wait`. A jitter of `0.0` (the default) disables the feature entirely.

### Thread-local strategy override

`JobRetry` uses `with_wait_strategy` internally. You can also use it directly:

```ruby
Hanikamu::RateLimit.with_wait_strategy(:raise) do
  MyService.new.execute  # raises RateLimitError instead of sleeping
end
```

This is useful outside ActiveJob, for example in tests or custom retry logic.

### `RateLimitError`

`RateLimitError` carries a `retry_after` attribute (Float, seconds) indicating how long until a slot opens:

```ruby
begin
  service.execute
rescue Hanikamu::RateLimit::RateLimitError => e
  e.retry_after # => 0.42
end
```

## UI Dashboard

The dashboard requires Rails (`actionpack`, `actionview`, `railties` >= 6.1).
These are **not** included as gem dependencies so non-Rails apps stay lightweight.

```ruby
# Gemfile (already present in a Rails app)
gem "actionpack",  ">= 6.1"
gem "actionview",  ">= 6.1"
gem "railties",    ">= 6.1"
```

Mount the engine:

```ruby
# config/routes.rb
require "hanikamu/rate_limit/ui"

Rails.application.routes.draw do
  mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"
end
```

### Authentication

The dashboard is **deny-by-default**. All endpoints return `403 Forbidden` until `ui_auth` is configured. The callable receives the engine's `DashboardController` instance (inherits from `ActionController::Base`, **not** your `ApplicationController`):

```ruby
Hanikamu::RateLimit.configure do |config|
  # Local requests only
  config.ui_auth = ->(controller) { controller.request.local? }

  # Devise / Warden
  config.ui_auth = ->(controller) { controller.request.env["warden"]&.user&.admin? }

  # Warden with custom scope
  config.ui_auth = ->(controller) {
    controller.request.env["warden"]&.user(:admin_user)&.access?(:metrics)
  }

  # Session-based
  config.ui_auth = ->(controller) { controller.session[:admin] == true }

  # Zero-arity (no controller needed)
  config.ui_auth = -> { Rails.env.development? }
end
```

When the callable returns falsy **or raises**, a `401 Unauthorized` is returned.

### Live streaming (SSE)

The dashboard uses Server-Sent Events for real-time updates. Each SSE connection holds a server thread for up to 1 minute (auto-reconnects transparently). Concurrent connections are capped to prevent thread exhaustion:

```ruby
Hanikamu::RateLimit.configure do |config|
  config.ui_max_sse_connections = 5   # conservative (default: 10)
  config.ui_max_sse_connections = nil # disable the limit (not recommended)
end
```

> **Tip:** With Puma `threads 5, 10` and `ui_max_sse_connections = 5`, five threads remain for regular requests.

### Dashboard features

- **Summary cards** — limits tracked, window size, bucket size, timestamp.
- **Redis info** — version, memory usage, peak memory, connected clients (live via SSE).
- **Per-limit cards** — current rate, hits/sec, blocked/sec, rolling counters (5 min, 24 h, all-time), 24-hour and 5-minute charts with blocked-period highlighting, override status pill.

### Metrics settings

| Setting                            | Default  | Description                        |
| ---------------------------------- | -------- | ---------------------------------- |
| `metrics_bucket_seconds`           | `300`    | Histogram bucket size (long view)  |
| `metrics_window_seconds`           | `86_400` | Rolling window (long view)         |
| `metrics_realtime_bucket_seconds`  | `1`      | Bucket size (short/realtime view)  |
| `metrics_realtime_window_seconds`  | `300`    | Rolling window (short view)        |

### Endpoints

| Method | Path                   | Description                   |
| ------ | ---------------------- | ----------------------------- |
| GET    | `/rate-limits`         | HTML dashboard                |
| GET    | `/rate-limits/metrics` | JSON snapshot of all metrics  |
| GET    | `/rate-limits/stream`  | SSE stream (`event: metrics`) |

### Resetting a limit

Registry limits can be reset from a Rails console or any Ruby context where the gem is loaded.
`reset_limit!` deletes both the sliding-window key **and** any active temporary override in Redis,
so the quota starts completely fresh:

```ruby
# Rails console / IRB
Hanikamu::RateLimit.reset_limit!(:external_api)
# => true
```

Inline limits (configured with `rate:` / `interval:` on `limit_method`) can be reset
via their auto-generated class method instead:

```ruby
MyService.reset_execute_limit!
```

### Redis memory safety

All metrics keys have TTLs to prevent unbounded growth:

| Key type           | TTL              | Notes                                     |
| ------------------ | ---------------- | ----------------------------------------- |
| Limits set         | 7 days           | Tracks known limit keys                   |
| Limit metadata     | 24 h + bucket    | Per-limit config hash                     |
| Override metadata  | 1 day            | Override remaining/reset snapshots         |
| Lifetime counters  | None             | Persistent all-time allowed/blocked counts |

## Error Handling

- **Redis unavailable** — `RateQueue#shift` logs a warning and returns `nil` (fail-open).
- **Rate limited (sleep strategy)** — blocks up to `max_wait_time`, then raises `RateLimitError`.
- **Rate limited (raise strategy)** — raises `RateLimitError` immediately with `retry_after`.

## Testing

```bash
make rspec
```

## Development

```bash
make shell    # bash inside the container
make cops     # RuboCop with auto-correct
make console  # IRB with the gem loaded
make bundle   # rebuild after Gemfile changes
```

## License

MIT
