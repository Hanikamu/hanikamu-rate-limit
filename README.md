# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting with a sliding window algorithm. Works across processes and threads by coordinating through Redis.

## Table of Contents

1. [Why Hanikamu::RateLimit?](#why-hanikamurate-limit)
2. [Quick Start](#quick-start)
3. [Configuration](#configuration)
4. [Usage](#usage)
5. [UI Dashboard](#ui-dashboard)
6. [Error Handling](#error-handling)
7. [Testing](#testing)
8. [Development](#development)
9. [License](#license)

## Why Hanikamu::RateLimit?

- **Use case**: You run 40 Sidekiq workers that all hit the same external marketing API capped at 20 requests per second. Without coordination, they’ll burst and trigger throttling. With a shared limit, every worker routes through the same Redis-backed window so aggregate throughput stays at 20 req/s across the whole fleet.
- **Distributed by design**: Limits are enforced through Redis so multiple app instances share a single limit.
- **Sliding window**: Limits are based on the most recent interval window, not fixed buckets.
- **Backoff with polling**: When a limit is hit, the limiter sleeps in short intervals until a slot opens.
- **Bounded waiting**: Callers can set a max wait time to avoid waiting indefinitely.
- **Minimal surface area**: A single mixin and a compact queue implementation.

## Quick Start

**1. Install the gem**

Requires Ruby 4.0 or later.

```ruby
# Gemfile
gem "hanikamu-rate-limit", "~> 0.2.0"
```

```bash
bundle install
```

**2. Configure Redis**

```ruby
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")
  config.check_interval = 0.25
  config.max_wait_time = 1.5

  config.register_limit(:external_api, rate: 5, interval: 0.5, check_interval: 0.5, max_wait_time: 5)
end
```

**3. Limit a method**

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  limit_method :execute, rate: 5, interval: 1.0

  def execute
    # work
  end
end
```

**4. Call it**

```ruby
MyService.new.execute
```

## Configuration

Available settings:

- `redis_url`: Redis connection URL (required).
- `check_interval`: default sleep interval between retries (default: 0.5 seconds).
- `max_wait_time`: max time to wait before raising (default: 2.0 seconds).
- `metrics_enabled`: enable metrics collection for the UI dashboard (default: `false`). Set to `true` to enable the dashboard. Can be overridden per-limit (see below).
- `register_limit`: define a named limit shared across classes.

Registered limit options:

- `rate` and `interval` (required).
- `check_interval`, `max_wait_time` (optional).
- `metrics`: enable/disable metrics for this limit (optional, inherits from `metrics_enabled`).

`key_prefix` is no longer configurable for registered limits; registry keys are derived from the registry name.

## Usage

Optional per-method overrides:

```ruby
limit_method :execute, rate: 5, interval: 1.0, check_interval: 0.1, max_wait_time: 3.0
```

You can also control metrics for a specific inline method:

```ruby
limit_method :execute, rate: 5, interval: 1.0, metrics: false
```

> **Note:** `metrics:` cannot be combined with `registry:` on `limit_method`.
> Registry-based methods always inherit the `metrics:` value from `register_limit`.

Metrics precedence (highest to lowest):

1. `metrics:` on `limit_method` — inline methods only (cannot be used with `registry:`).
2. `metrics:` on `register_limit` — applies to all methods using that registry.
3. `config.metrics_enabled` — global default (`false`).

Optional block called each time the limiter sleeps:

```ruby
limit_method :execute, rate: 5, interval: 1.0 do |sleep_time|
  Rails.logger.info("Rate limited, sleeping #{sleep_time}s")
end
```

Use a registered limit shared across classes:

```ruby
class ExternalApiClient
  extend Hanikamu::RateLimit::Mixin

  limit_method :execute, registry: :external_api

  def execute
    # work
  end
end
```

You must provide either `registry:` or `rate:` — combining them raises `ArgumentError`.
When `registry:` is used, it must be the only limit-related option (no `rate:`, `interval:`, `check_interval:`, or `max_wait_time:` overrides).

Registry precedence (highest to lowest):

1. Registered limit options.
2. Global defaults from `Hanikamu::RateLimit.configure`.

Reset method is generated automatically:

```ruby
MyService.reset_execute_limit!
```

### Dynamic overrides

Dynamic overrides only apply to **registry-based limits** (methods using `limit_method` with `registry:`). Methods limited with inline `rate:` / `interval:` options are not affected.

When an external API returns rate-limit headers (e.g. `X-RateLimit-Remaining`, `X-RateLimit-Reset`), you can temporarily override a registered limit to match the real window:

```ruby
Hanikamu::RateLimit.register_temporary_limit(:external_api, remaining: 175, reset: 60)
```

This stores a Redis counter with `remaining` requests allowed and a TTL of `reset` seconds. While the override is active, the fixed-window counter is used instead of the sliding window. When the TTL expires, the original registered limit resumes automatically.

Behavior when the override is exhausted (`remaining` reaches 0):

- If the remaining TTL exceeds `max_wait_time`, a `RateLimitError` is raised **immediately** — no polling occurs because the fixed-window quota won't reset until the TTL expires.
- If the remaining TTL is within `max_wait_time`, the limiter polls until the override expires and falls back to the sliding window.

This differs from the sliding window, which always polls in short intervals since entries continuously slide out of the window.

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
        reset: response.headers["X-RateLimit-Reset"]
      )
    end

    response
  end
end
```

### Class methods

To rate limit class methods, apply the mixin to the singleton class:

```ruby
class MyService
  class << self
    extend Hanikamu::RateLimit::Mixin

    limit_method :call, rate: 5, interval: 1.0

    def call
      # work
    end
  end
end
```

You can also use registered limits:

```ruby
Hanikamu::RateLimit.configure do |config|
  config.register_limit(:external_api, rate: 5, interval: 1.0)
end

class MyService
  class << self
    extend Hanikamu::RateLimit::Mixin

    limit_method :call, registry: :external_api

    def call
      # work
    end
  end
end

```

## UI Dashboard

The dashboard requires Rails (`actionpack`, `actionview`, `railties` >= 6.1).
These are **not** included as gem dependencies so non-Rails applications stay
lightweight. In a Rails app they are already available; otherwise add them to
your Gemfile:

```ruby
gem "actionpack", ">= 6.1"
gem "actionview", ">= 6.1"
gem "railties", ">= 6.1"
```

Mount the dashboard engine in your Rails routes:

```ruby
# config/routes.rb
require "hanikamu/rate_limit/ui"

Rails.application.routes.draw do
  mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"
end
```

### Authentication

Protect the dashboard with an authentication hook. The callable receives the
engine's `DashboardController` instance (inherits from `ActionController::Base`,
**not** your `ApplicationController`). This means helpers like `current_user` are
not available directly — use the Rack env, session, or Warden middleware instead:

```ruby
Hanikamu::RateLimit.configure do |config|
  # Restrict to local requests
  config.ui_auth = ->(controller) { controller.request.local? }

  # Using Devise / Warden (standard scope)
  config.ui_auth = ->(controller) { controller.request.env["warden"]&.user&.admin? }

  # Using Devise / Warden with a custom scope (e.g. :admin_user)
  config.ui_auth = ->(controller) {
    admin = controller.request.env["warden"]&.user(:admin_user)
    admin&.access?(:metrics)
  }

  # Using session
  config.ui_auth = ->(controller) { controller.session[:admin] == true }

  # Zero-arity form (no controller needed)
  config.ui_auth = -> { Rails.env.development? }

  # Allow all access (development only — NOT recommended for production)
  config.ui_auth = ->(_controller) { true }
end
```

**`ui_auth` must be configured** before the dashboard will serve any requests.
When `ui_auth` is `nil` (the default), all dashboard endpoints respond with
`403 Forbidden`. This deny-by-default approach prevents accidental exposure of
rate limit metrics and Redis internals in production.

When the callable returns a falsy value **or raises an exception**, a
`401 Unauthorized` response is returned. Authentication protects all endpoints:
the dashboard, the JSON metrics endpoint, and the SSE stream.

### Live streaming (SSE)

The dashboard uses **Server-Sent Events** for real-time updates instead of
polling. The browser connects to the `/stream` endpoint and receives metrics
pushes every 2 seconds. Connections are automatically closed after 5 minutes
to prevent thread exhaustion; the browser reconnects transparently.

#### Threading implications

Each SSE connection holds a Puma (or other threaded server) thread for up to
5 minutes. To prevent thread pool exhaustion, the engine limits concurrent SSE
connections (default: **10**). When the limit is reached, new stream requests
receive a `503 Service Unavailable` response and the browser retries
automatically via the EventSource reconnect mechanism.

Configure the limit to match your server's thread budget:

```ruby
Hanikamu::RateLimit.configure do |config|
  config.ui_max_sse_connections = 5   # conservative
  config.ui_max_sse_connections = nil # disable the limit (not recommended)
end
```

> **Tip:** If you use Puma, ensure `threads` is set high enough to accommodate
> your normal request load **plus** the SSE slots. For example, with
> `threads 5, 10` and `ui_max_sse_connections = 5`, five threads remain
> available for regular requests.

### Dashboard features

- **Summary cards** — limits tracked, window size, bucket size, timestamp.
- **Redis info cards** — Redis version, memory usage, peak memory, connected
  clients. Updated live via SSE (similar to Sidekiq's server info panel).
- **Per-limit cards** with:
  - Current rate limit, hits/sec, and blocked/sec stats.
  - Rolling counters for 5 minutes, 24 hours, and all-time totals
    (allowed and blocked).
  - **24-hour chart** — allowed requests and limit line over the last day.
  - **5-minute chart** — allowed requests and limit line at 1-second resolution.
  - **Override pill** — shows remaining requests and reset time when a dynamic
    override is active.

### Metrics configuration

| Setting                            | Default    | Description                        |
| ---------------------------------- | ---------- | ---------------------------------- |
| `metrics_bucket_seconds`           | `300`      | Histogram bucket size (long view)  |
| `metrics_window_seconds`           | `86_400`   | Rolling window (long view)         |
| `metrics_realtime_bucket_seconds`  | `1`        | Bucket size (short/realtime view)  |
| `metrics_realtime_window_seconds`  | `300`      | Rolling window (short view)        |

### Endpoints

| Method | Path                  | Description                          |
| ------ | --------------------- | ------------------------------------ |
| GET    | `/rate-limits`        | HTML dashboard                       |
| GET    | `/rate-limits/metrics`| JSON snapshot of all metrics         |
| GET    | `/rate-limits/stream` | SSE stream (event: `metrics`)        |

### Redis memory safety

All metrics keys have TTLs to prevent unbounded growth:

| Key type          | TTL       | Notes                                   |
| ----------------- | --------- | --------------------------------------- |
| Limits set        | 7 days    | Tracks known limit keys                 |
| Limit metadata    | 24h + bucket | Per-limit config hash                |
| Override metadata | 1 day     | Override remaining/reset snapshots       |
| Lifetime counters | None      | Persistent all-time allowed/blocked counts |

Redis writes are pipelined to minimize round-trips.

## Error Handling

If Redis is unavailable, `RateQueue#shift` logs a warning and returns `nil`.

## Testing

```bash
make rspec
```

## Development

```bash
make shell
```

## License

MIT
