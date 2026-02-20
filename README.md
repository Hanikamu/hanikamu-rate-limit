# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting for Ruby. Coordinates request throughput across processes and threads so you never exceed an API's quota — even with dozens of workers.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Database Setup (v0.5+)](#database-setup-v05)
3. [Usage Examples](#usage-examples)
4. [Adaptive Rate Limiting](#adaptive-rate-limiting)
5. [Background Jobs](#background-jobs)
6. [UI Dashboard](#ui-dashboard)
7. [Configuration Reference](#configuration-reference)
8. [Error Handling](#error-handling)
9. [Testing](#testing)
10. [Development](#development)

---

## Quick Start

Requires **Ruby 4.0+** and a running **Redis** instance. Adaptive rate limiting and the Learning UI also require **PostgreSQL** and **ActiveRecord** — see [Database Setup](#database-setup-v050).

```ruby
# Gemfile
gem "hanikamu-rate-limit", "~> 0.5"
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
    # your code here
  end
end

MyService.new.execute  # waits automatically if the limit is reached
```

That's it — the limiter coordinates across all processes sharing the same Redis.

---

## Database Setup (v0.5+)

Adaptive rate limiting, the Learning UI, and historical charts require **PostgreSQL**. Fixed-rate limiting only needs Redis.

**1. Generate migrations**

```bash
rails generate hanikamu_rate_limit:install
rails db:migrate
```

This creates two tables:
- `hanikamu_rate_limit_events` — captured exceptions/responses for the Learning UI
- `hanikamu_rate_limit_snapshots` — periodic rate snapshots for historical charts

**2. Configure ActiveRecord Encryption**

Sensitive columns (exception messages, response headers, response body snippets) are encrypted at rest. Set up Rails encryption keys if you haven't already:

```bash
rails credentials:edit
```

Add the `active_record_encryption` section if missing — Rails will guide you through the setup.

**3. Optional: configure retention**

```ruby
Hanikamu::RateLimit.configure do |config|
  config.event_retention    = 7.days   # how long captured events are kept
  config.snapshot_interval  = 10       # seconds between rate snapshots
  config.snapshot_retention = 30.days  # how long snapshots are kept
end
```

Run `Hanikamu::RateLimit::Storage::RetentionCleanup.run!` periodically (e.g. daily via cron or Sidekiq) to prune expired records.

---

## Usage Examples

### 1. Inline limit (single class)

Pass `rate:` and `interval:` directly on the method:

```ruby
class MyService
  extend Hanikamu::RateLimit::Mixin

  # 5 requests per second
  limit_method :execute, rate: 5, interval: 1.0

  def execute = "done"
end
```

### 2. Shared limit (multiple classes, one quota)

Register a named limit once, reference it everywhere:

```ruby
# config/initializers/hanikamu_rate_limit.rb
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")
  config.register_limit(:stripe_api, rate: 20, interval: 1.0)
end
```

```ruby
class PaymentService
  extend Hanikamu::RateLimit::Mixin
  limit_method :charge, registry: :stripe_api
  def charge(amount) = Stripe::Charge.create(amount: amount)
end

class RefundService
  extend Hanikamu::RateLimit::Mixin
  limit_method :refund, registry: :stripe_api
  def refund(charge_id) = Stripe::Refund.create(charge: charge_id)
end
```

Both classes share the same 20 req/s quota in Redis.

### 3. Dynamic overrides from API headers

Feed rate-limit headers from an API response back into the gem:

```ruby
class StripeClient
  extend Hanikamu::RateLimit::Mixin
  limit_method :call, registry: :stripe_api

  def call
    response = http_client.get("/v1/charges")

    if response.headers["X-RateLimit-Remaining"]
      Hanikamu::RateLimit.register_temporary_limit(
        :stripe_api,
        remaining: response.headers["X-RateLimit-Remaining"],
        reset:     response.headers["X-RateLimit-Reset"],
        reset_kind: :unix
      )
    end

    response
  end
end
```

While the temporary limit is active, the gem uses it instead of the registered one. When it expires, the original limit resumes automatically.

`reset_kind` tells the gem how to interpret the `reset:` value:

| `reset_kind`  | What to pass                  | Example                 |
| ------------- | ----------------------------- | ----------------------- |
| `:seconds`    | Seconds until reset (default) | `reset: 60`             |
| `:unix`       | Unix timestamp                | `reset: 1740000000`     |
| `:datetime`   | `Time` or `DateTime` object   | `reset: Time.now + 60`  |

### 4. Class methods

```ruby
class MyService
  class << self
    extend Hanikamu::RateLimit::Mixin
    limit_method :call, registry: :stripe_api
    def call = "work"
  end
end
```

### 5. Callbacks

```ruby
limit_method :execute, rate: 5, interval: 1.0 do |sleep_time|
  Rails.logger.info("Rate limited, waiting #{sleep_time}s")
end
```

### 6. Resetting limits

```ruby
# Registry limit — clears the counter and any active temporary override
Hanikamu::RateLimit.reset_limit!(:stripe_api)

# Inline limit — auto-generated reset method
MyService.reset_execute_limit!
```

---

## Adaptive Rate Limiting

When you **don't know** an API's exact rate limit — or it changes dynamically — use adaptive limits. The gem discovers the safe throughput automatically.

### How it works

1. **Start** at a baseline rate you choose (e.g. 30 req/s).
2. **Probe upward** — after the sliding window fills completely and enough consecutive successes accumulate, the rate increases by +1.
3. **Drop on errors** — when a request triggers an error (a 429, a timeout, etc.), the event is captured and stored. You classify it in the **Learning UI** as `"rate_limit"` (real signal) or `"ignored"` (noise). Once classified, the rate drops one below the rate that caused the error.
4. **Learn a ceiling** — repeated drops in the same zone build confidence. The higher the confidence, the harder it is to probe past the ceiling and the longer the cooldown between attempts.
5. **Auto-inherit** — future events matching the same signature (registry + type + status/exception) inherit the classification automatically. You only classify once.

Over time the rate converges just below the API's real limit. If the limit changes, new unclassified events appear; classify them and the system adapts. No code changes, no redeployment.

### Minimal setup

```ruby
Hanikamu::RateLimit.configure do |config|
  config.redis_url = ENV.fetch("REDIS_URL")

  config.register_adaptive_limit(:twitter_api,
    initial_rate: 5, interval: 1,
    error_classes: [Twitter::TooManyRequests]
  )
end
```

```ruby
class TwitterClient
  extend Hanikamu::RateLimit::Mixin
  limit_method :search, registry: :twitter_api

  def search(query)
    client.search(query)
  end
end
```

That's it. On success the rate gradually probes upward; on `TooManyRequests` the event is captured for the Learning UI and — once classified — the rate drops below the error point.

### Full setup (with header parsing)

```ruby
config.register_adaptive_limit(:external_api,
  initial_rate:          2,
  interval:              1,
  min_rate:              1,
  max_rate:              50,
  error_classes:         [RestClient::TooManyRequests],

  # Extract headers from error responses (e.g. 429s)
  header_parser: ->(error) {
    headers = error.response&.headers
    next unless headers
    { remaining: headers[:x_ratelimit_remaining],
      reset:     headers[:x_ratelimit_reset],
      reset_kind: :unix }
  },

  # Extract headers from successful responses
  response_parser: ->(response) {
    headers = response.headers rescue nil
    next unless headers
    { remaining: headers["X-RateLimit-Remaining"],
      reset:     headers["X-RateLimit-Reset"],
      reset_kind: :unix }
  }
)
```

### Decoupling feedback from the return value

By default, `response_parser` receives whatever your method returns. If you don't want to couple your return value to the adaptive logic, use `hanikamu_adaptive_feedback` inside the method body instead. The wrapper picks it up after the method returns and feeds it to `response_parser`.

```ruby
class ApiClient
  extend Hanikamu::RateLimit::Mixin
  limit_method :fetch, registry: :external_api

  def fetch(id)
    response = http_client.get("/items/#{id}")

    # Feed raw response data to the adaptive limiter...
    hanikamu_adaptive_feedback(:fetch, registry: :external_api,
      status: response.code.to_i,
      body:   response.body)

    # ...but return a clean domain object.
    JSON.parse(response.body)
  end
end
```

The `response_parser` lambda receives `{ status: 429, body: "..." }` (the feedback) instead of the parsed JSON (the return value). This keeps your method's API clean while still feeding the adaptive system what it needs.

### Manual header reporting

For APIs that send rate-limit headers, you can feed them back directly:

```ruby
class ExternalApiClient
  extend Hanikamu::RateLimit::Mixin
  limit_method :call_api, registry: :external_api

  def call_api
    response = http_client.get("/endpoint")
    report_rate_limit_headers(:external_api,
      remaining: response.headers["X-RateLimit-Remaining"],
      reset:     response.headers["X-RateLimit-Reset"],
      reset_kind: :unix
    )
    response
  end
end
```

### Resetting adaptive limits

```ruby
Hanikamu::RateLimit.reset_limit!(:external_api)
# Clears the sliding window, any temporary override, and all learned state.
# Rate reverts to initial_rate.
```

---

## Background Jobs

With the default `:sleep` strategy, a rate-limited call blocks the worker thread. `JobRetry` makes jobs **re-enqueue themselves** instead, freeing the thread instantly.

### ActiveJob

```ruby
class RateLimitedJob < ApplicationJob
  extend Hanikamu::RateLimit::JobRetry
  rate_limit_retry

  def perform
    MyService.new.execute
  end
end
```

### Sidekiq native workers

Requires Sidekiq >= 8.1.

```ruby
class RateLimitedWorker
  include Sidekiq::Worker
  extend Hanikamu::RateLimit::JobRetry
  rate_limit_retry worker: :sidekiq, attempts: 10

  def perform
    MyService.new.execute
  end
end
```

`attempts` = total executions (initial + retries), so `attempts: 10` maps to `sidekiq_options retry: 9`.

### Jitter

Prevents thundering herds when many jobs retry simultaneously:

```ruby
config.jitter = 0.15  # adds 0–15 % random spread to each wait
```

### Manual strategy override

```ruby
Hanikamu::RateLimit.with_wait_strategy(:raise) do
  MyService.new.execute  # raises RateLimitError instead of sleeping
end
```

---

## UI Dashboard

A built-in real-time dashboard. **Requires Rails** (>= 6.1).

```ruby
# config/initializers/hanikamu_rate_limit.rb
Hanikamu::RateLimit.configure do |config|
  config.metrics_enabled = true
  config.ui_auth = ->(controller) { controller.request.local? }
end
```

```ruby
# config/routes.rb
require "hanikamu/rate_limit/ui"
mount Hanikamu::RateLimit::UI::Engine => "/rate-limits"
```

The dashboard is **deny-by-default** — all endpoints return `403` until you configure `ui_auth`.

#### Auth examples

```ruby
config.ui_auth = ->(c) { c.request.env["warden"]&.user&.admin? }  # Devise
config.ui_auth = ->(c) { c.session[:admin] == true }               # Session
config.ui_auth = -> { Rails.env.development? }                     # Dev only
```

#### Endpoints

| Method | Path                   | Description                   |
| ------ | ---------------------- | ----------------------------- |
| GET    | `/rate-limits`         | HTML dashboard                |
| GET    | `/rate-limits/metrics` | JSON snapshot of all metrics  |
| GET    | `/rate-limits/stream`  | SSE stream (`event: metrics`) |

---

## Configuration Reference

### Global settings

```ruby
Hanikamu::RateLimit.configure do |config|
  # ── Required ──
  config.redis_url = ENV.fetch("REDIS_URL")

  # ── Rate limiting behaviour ──
  config.check_interval  = 0.5     # seconds between retries when the limit is hit
  config.max_wait_time   = 2.0     # seconds — give up and raise RateLimitError
  config.wait_strategy   = :sleep  # :sleep (block thread) or :raise (raise immediately)
  config.jitter          = 0.0     # proportional random spread (0.15 = up to 15 %)

  # ── Metrics & dashboard ──
  config.metrics_enabled                 = false   # must be true for the UI dashboard
  config.metrics_bucket_seconds          = 300     # 24-hour chart bucket size
  config.metrics_window_seconds          = 86_400  # 24-hour chart rolling window
  config.metrics_realtime_bucket_seconds = 1       # 5-minute chart bucket size
  config.metrics_realtime_window_seconds = 300     # 5-minute chart rolling window

  # ── Dashboard auth & SSE ──
  config.ui_auth                = nil  # callable — deny-by-default when nil
  config.ui_max_sse_connections = 10   # cap concurrent SSE connections
end
```

| Setting                            | Default  | Description                                                          |
| ---------------------------------- | -------- | -------------------------------------------------------------------- |
| `redis_url`                        | —        | Redis connection URL. **Required.**                                  |
| `check_interval`                   | `0.5`    | Seconds between retries when a limit is hit.                         |
| `max_wait_time`                    | `2.0`    | Max seconds to wait before raising `RateLimitError`.                 |
| `wait_strategy`                    | `:sleep` | `:sleep` blocks the thread; `:raise` raises immediately.             |
| `jitter`                           | `0.0`    | Random spread added to wait times (0.15 = up to 15 %).               |
| `metrics_enabled`                  | `false`  | Enable metrics collection. Required for the UI dashboard.            |
| `metrics_bucket_seconds`           | `300`    | 24-hour chart bucket size.                                           |
| `metrics_window_seconds`           | `86_400` | 24-hour chart rolling window.                                        |
| `metrics_realtime_bucket_seconds`  | `1`      | 5-minute chart bucket size.                                          |
| `metrics_realtime_window_seconds`  | `300`    | 5-minute chart rolling window.                                       |
| `ui_auth`                          | `nil`    | Callable for dashboard auth. Deny-by-default when nil.               |
| `ui_max_sse_connections`           | `10`     | Max concurrent SSE connections. `nil` = no limit.                    |

### register_limit (fixed rate)

```ruby
config.register_limit(:stripe_api,
  rate:           20,    # max requests per interval (required)
  interval:       1.0,   # window size in seconds (required)
  check_interval: 0.1,   # override global check_interval (optional)
  max_wait_time:  5.0,   # override global max_wait_time (optional)
  metrics:        true    # override global metrics_enabled (optional)
)
```

| Option           | Required | Default | Description                                         |
| ---------------- | -------- | ------- | --------------------------------------------------- |
| `rate`           | Yes      | —       | Max requests allowed per `interval`.                 |
| `interval`       | Yes      | —       | Time window in seconds.                              |
| `check_interval` | No       | global  | Override global `check_interval` for this limit.     |
| `max_wait_time`  | No       | global  | Override global `max_wait_time` for this limit.      |
| `metrics`        | No       | global  | Override `metrics_enabled` (`true` / `false`).       |

### register_adaptive_limit

```ruby
config.register_adaptive_limit(:external_api,
  # ── Required ──
  initial_rate:          5,      # starting rate (requests per interval)
  interval:              1,      # window size in seconds

  # ── Rate bounds ──
  min_rate:              1,      # floor — never drops below this
  max_rate:              50,     # ceiling — never probes above this (nil = no upper bound)

  # ── Ceiling tuning ──
  utilization_threshold: 1.0,    # sliding window fill ratio required before probing (0.0–1.0)
  ceiling_threshold:     0.9,    # base utilisation needed to break through the error ceiling
  probe_cooldown:        30,     # base seconds between probe attempts near the ceiling
  max_probe_cooldown:    300,    # hard cap on effective cooldown (prevents stalls)

  # ── Error & response feedback ──
  error_classes:    [RestClient::TooManyRequests],
  header_parser:    ->(error)    { ... },  # extract headers from errors (429s)
  response_parser:  ->(response) { ... },  # extract headers from successes

  # ── Per-limit overrides ──
  check_interval: 0.1,
  max_wait_time:  5.0,
  metrics:        true
)
```

| Option                    | Required | Default | Description                                                                     |
| ------------------------- | -------- | ------- | ------------------------------------------------------------------------------- |
| `initial_rate`            | Yes      | —       | Starting rate (requests per `interval`).                                        |
| `interval`                | Yes      | —       | Window size in seconds.                                                         |
| `min_rate`                | No       | `1`     | Floor for the rate after drops.                                                 |
| `max_rate`                | No       | `nil`   | Ceiling for the rate. `nil` = no upper bound.                                   |
| `utilization_threshold`   | No       | `1.0`   | Sliding window fill ratio required before probing higher (0.0–1.0).             |
| `ceiling_threshold`       | No       | `0.9`   | Base utilisation needed to break through the error ceiling.                     |
| `probe_cooldown`          | No       | `30`    | Base seconds between probes near the ceiling. Scales with hits + confidence.    |
| `max_probe_cooldown`      | No       | `300`   | Hard cap on effective cooldown (seconds). Prevents runaway cooldown from high-traffic APIs. |
| `error_classes`           | No       | `[]`    | Exception classes that trigger event capture.                                   |
| `header_parser`           | No       | `nil`   | Lambda receiving the caught error; return `{ remaining:, reset: }` or nil.      |
| `response_parser`         | No       | `nil`   | Lambda receiving each response (or feedback); return a Hash to capture it.      |
| `check_interval`          | No       | global  | Override global `check_interval` for this limit.                                |
| `max_wait_time`           | No       | global  | Override global `max_wait_time` for this limit.                                 |
| `metrics`                 | No       | global  | Override `metrics_enabled` for this limit.                                      |

### rate_limit_retry (background jobs)

```ruby
extend Hanikamu::RateLimit::JobRetry
rate_limit_retry(
  attempts:      :unlimited,  # total executions (initial + retries), or :unlimited
  fallback_wait: 5,           # seconds to wait if error has no retry_after
  worker:        :active_job  # :active_job or :sidekiq
)
```

| Option          | Default       | Description                                                          |
| --------------- | ------------- | -------------------------------------------------------------------- |
| `attempts`      | `:unlimited`  | Total executions. `:unlimited` retries forever.                       |
| `fallback_wait` | `5`           | Seconds to wait if the error has no `retry_after` value.             |
| `worker`        | `:active_job` | `:active_job` for ActiveJob, `:sidekiq` for native Sidekiq workers.  |

---

## Error Handling

| Scenario                    | Behaviour                                                               |
| --------------------------- | ----------------------------------------------------------------------- |
| **Redis unavailable**       | Logs a warning and allows the request through (fail-open).              |
| **Rate limited (`:sleep`)** | Blocks up to `max_wait_time`, then raises `RateLimitError`.            |
| **Rate limited (`:raise`)** | Raises `RateLimitError` immediately with a `retry_after` value.        |

```ruby
begin
  service.execute
rescue Hanikamu::RateLimit::RateLimitError => e
  e.retry_after  # => 0.42 (seconds until a slot opens)
end
```

---

## Testing

In tests, raise immediately instead of blocking:

```ruby
around do |example|
  Hanikamu::RateLimit.with_wait_strategy(:raise) { example.run }
end
```

Running the gem's own tests:

```bash
make rspec
```

---

## Development

```bash
make shell    # bash inside the container
make cops     # RuboCop with auto-correct
make console  # IRB with the gem loaded
make bundle   # rebuild after Gemfile changes
```

## License

MIT
