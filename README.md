# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting for Ruby. Coordinates request throughput across processes and threads so you never exceed an API's quota — even with dozens of workers.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Configuration](#configuration)
3. [Usage](#usage)
   - [Inline limits](#inline-limits)
   - [Shared limits (registry)](#shared-limits-registry)
   - [Dynamic overrides from API headers](#dynamic-overrides-from-api-headers)
   - [Class methods](#class-methods)
   - [Callbacks](#callbacks)
4. [Resetting limits](#resetting-limits)
5. [Background Jobs (ActiveJob)](#background-jobs-activejob)
6. [UI Dashboard](#ui-dashboard)
7. [Error Handling](#error-handling)
8. [Testing](#testing)
9. [Development](#development)
10. [License](#license)

## Quick Start

Requires Ruby 4.0+ and a running Redis instance.

**1. Install the gem**

```ruby
# Gemfile
gem "hanikamu-rate-limit", "~> 0.4"
```

```bash
bundle install
```

**2. Configure Redis**

```ruby
# config/initializers/hanikamu_rate_limit.rb
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")
end
```

**3. Add a limit to any method**

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  # Allow at most 5 calls per second
  limit_method :execute, rate: 5, interval: 1.0

  def execute
    # work
  end
end

MyService.new.execute # waits automatically if the limit is reached
```

That's it. The limiter coordinates across all processes sharing the same Redis instance.

## Configuration

```ruby
Hanikamu::RateLimit.configure do |config|
  # Required
  config.redis_url = ENV.fetch("REDIS_URL")

  # Optional — tune how the limiter waits when a limit is reached
  config.check_interval  = 0.25   # how often to retry (seconds)
  config.max_wait_time   = 1.5    # give up and raise after this many seconds
  config.wait_strategy   = :sleep # :sleep (block the thread) or :raise (raise immediately)
  config.jitter          = 0.15   # add up to 15 % random spread to prevent thundering herds
  config.metrics_enabled = true   # required if you want the UI dashboard

  # Named limits — share one quota across multiple classes
  config.register_limit(:external_api,
    rate: 20, interval: 1.0,            # 20 requests per second
    check_interval: 0.1, max_wait_time: 5
  )
end
```

### Global settings

| Setting          | Default  | Description                                                         |
| ---------------- | -------- | ------------------------------------------------------------------- |
| `redis_url`      | —        | Redis connection URL (**required**).                                |
| `check_interval` | `0.5`    | Seconds between retries when a limit is hit.                        |
| `max_wait_time`  | `2.0`    | Max seconds to wait before raising `RateLimitError`.                |
| `wait_strategy`  | `:sleep` | `:sleep` blocks the thread; `:raise` raises immediately.            |
| `jitter`         | `0.0`    | Random spread added to wait times to prevent thundering herds.      |
| `metrics_enabled`| `false`  | Enable metrics collection. **Must be `true`** for the UI dashboard. |

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

Best for limits that apply to a single class. Pass `rate:` and `interval:` directly:

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  # 5 requests per second
  limit_method :execute, rate: 5, interval: 1.0

  # 10 requests per minute, with custom wait settings and metrics disabled
  limit_method :fetch, rate: 10, interval: 60, check_interval: 0.1, max_wait_time: 3.0, metrics: false

  def execute = "done"
  def fetch   = "fetched"
end
```

### Shared limits (registry)

Best when multiple classes must share the same quota (e.g. different services calling the same external API). Define the limit once in the initializer, then reference it by name:

```ruby
# config/initializers/hanikamu_rate_limit.rb
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")
  config.register_limit(:external_api, rate: 20, interval: 1.0)
end
```

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

Both classes count against the same 20 req/s quota in Redis. You cannot combine `registry:` with inline options like `rate:` or `interval:`.

### Dynamic overrides from API headers

> Only works with **registry-based** limits.

Many APIs return rate-limit headers telling you how many requests you have left and when the window resets. You can feed these directly into the gem so it respects the API's actual limits:

```ruby
Hanikamu::RateLimit.register_temporary_limit(
  :external_api,
  remaining: response.headers["X-RateLimit-Remaining"],
  reset:     response.headers["X-RateLimit-Reset"],
  reset_kind: :unix
)
```

While active, the gem uses this temporary limit instead of the registered one. When it expires, the original limit resumes automatically.

#### `reset_kind` option

APIs express the reset value in different formats. Use `reset_kind:` to tell the gem what you're passing:

| `reset_kind`  | What to pass                  | Example                              |
| ------------- | ----------------------------- | ------------------------------------ |
| `:seconds`    | Seconds until reset (default) | `reset: 60`                          |
| `:unix`       | Unix timestamp (int/string)   | `reset: 1740000000`                  |
| `:datetime`   | `Time` or `DateTime` object   | `reset: Time.now + 60`              |

> **Safety:** With `:seconds` (default), values above 86,400 raise `ArgumentError` to catch accidental Unix timestamps.

#### Full example — API client with dynamic overrides

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
        reset:     response.headers["X-RateLimit-Reset"],
        reset_kind: :unix  # or :seconds depending on the API
      )
    end

    response
  end
end
```

#### What happens when remaining reaches 0?

- If the reset time is **longer** than `max_wait_time` → `RateLimitError` is raised immediately.
- If the reset time is **shorter** than `max_wait_time` → the limiter waits, then resumes with the original limit.

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

An optional block is called each time the limiter waits:

```ruby
limit_method :execute, rate: 5, interval: 1.0 do |sleep_time|
  Rails.logger.info("Rate limited, waiting #{sleep_time}s")
end
```

## Resetting limits

Clear a registry limit's counter and any active override so the quota starts fresh:

```ruby
Hanikamu::RateLimit.reset_limit!(:external_api)
# => true
```

Inline limits have an auto-generated reset method:

```ruby
MyService.reset_execute_limit!
```

## Background Jobs (ActiveJob)

### The problem

With the default `:sleep` strategy, a rate-limited call blocks the worker thread. If enough jobs hit the limit at once, all your Sidekiq threads can stall.

### The solution

`JobRetry` makes rate-limited jobs **re-enqueue themselves** instead of blocking. The thread is freed instantly and the job retries after the wait period.

```ruby
class RateLimitedJob < ApplicationJob
  extend Hanikamu::RateLimit::JobRetry
  rate_limit_retry

  def perform
    MyService.new.execute
  end
end
```

When `MyService#execute` hits a rate limit inside this job, it raises `RateLimitError` (instead of sleeping), and the job automatically calls `retry_job(wait: ...)` with the correct delay.

The same service still works normally outside of jobs — it sleeps as expected when called synchronously.

### `rate_limit_retry` options

| Option          | Default      | Description                                                              |
| --------------- | ------------ | ------------------------------------------------------------------------ |
| `attempts`      | `:unlimited` | Max retries. `:unlimited` retries forever; an integer caps the attempts. |
| `fallback_wait` | `5`          | Seconds to wait if the error has no `retry_after` value.                 |

```ruby
extend Hanikamu::RateLimit::JobRetry
rate_limit_retry attempts: 20, fallback_wait: 10
```

### Jitter

When many jobs are rate-limited at the same time they will all retry at the same instant, creating a spike. `jitter` adds random spread to prevent this:

```ruby
Hanikamu::RateLimit.configure do |config|
  config.jitter = 0.15 # adds 0–15 % random spread to each wait
end
```

### Manual strategy override

You can switch to the raise strategy for any block of code, not just ActiveJob:

```ruby
Hanikamu::RateLimit.with_wait_strategy(:raise) do
  MyService.new.execute  # raises RateLimitError instead of sleeping
end
```

## UI Dashboard

A built-in dashboard with real-time updates. **Requires Rails** (`actionpack`, `actionview`, `railties` >= 6.1) — these are already present in any Rails app.

### Setup

**1. Enable metrics**

```ruby
Hanikamu::RateLimit.configure do |config|
  config.metrics_enabled = true
end
```

**2. Mount the engine**

```ruby
# config/routes.rb
require "hanikamu/rate_limit/ui"

Rails.application.routes.draw do
  mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"
end
```

**3. Configure authentication**

The dashboard is **deny-by-default** — all endpoints return `403` until you configure `ui_auth`:

```ruby
Hanikamu::RateLimit.configure do |config|
  # Local requests only
  config.ui_auth = ->(controller) { controller.request.local? }

  # Devise / Warden
  config.ui_auth = ->(controller) { controller.request.env["warden"]&.user&.admin? }

  # Session-based
  config.ui_auth = ->(controller) { controller.session[:admin] == true }

  # Always allow (development only)
  config.ui_auth = -> { Rails.env.development? }
end
```

The callable receives the engine's `DashboardController` instance. When it returns falsy or raises, a `401` is returned.

### What the dashboard shows

- **Summary** — total limits tracked, window and bucket sizes.
- **Redis info** — version, memory usage, connected clients (updates live).
- **Per-limit cards** — current rate, requests/sec, blocked/sec, rolling counters (5 min, 24 h, all-time), charts with blocked-period highlighting, and override status.

### SSE connection limit

The dashboard streams live updates via Server-Sent Events. Each connection holds a thread for up to 1 minute (reconnects automatically). You can cap concurrent connections:

```ruby
config.ui_max_sse_connections = 5   # conservative (default: 10)
config.ui_max_sse_connections = nil  # no limit (not recommended)
```

### Metrics settings

| Setting                            | Default  | Description                                        |
| ---------------------------------- | -------- | -------------------------------------------------- |
| `metrics_bucket_seconds`           | `300`    | Bucket size for the 24-hour chart (5 min default)  |
| `metrics_window_seconds`           | `86_400` | How far back the 24-hour chart goes                |
| `metrics_realtime_bucket_seconds`  | `1`      | Bucket size for the 5-minute chart (1 sec default) |
| `metrics_realtime_window_seconds`  | `300`    | How far back the 5-minute chart goes               |

### Endpoints

| Method | Path                   | Description                   |
| ------ | ---------------------- | ----------------------------- |
| GET    | `/rate-limits`         | HTML dashboard                |
| GET    | `/rate-limits/metrics` | JSON snapshot of all metrics  |
| GET    | `/rate-limits/stream`  | SSE stream (`event: metrics`) |

## Error Handling

| Scenario                    | Behaviour                                                               |
| --------------------------- | ----------------------------------------------------------------------- |
| **Redis unavailable**       | Logs a warning and allows the request through (fail-open).              |
| **Rate limited (`:sleep`)** | Blocks up to `max_wait_time`, then raises `RateLimitError`.            |
| **Rate limited (`:raise`)** | Raises `RateLimitError` immediately with a `retry_after` value.        |

Catching the error:

```ruby
begin
  service.execute
rescue Hanikamu::RateLimit::RateLimitError => e
  e.retry_after # => 0.42 (seconds until a slot opens)
end
```

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
