# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting for Ruby. Coordinates request throughput across processes and threads so you never exceed an API's quota — even with dozens of workers.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Database Setup (v0.5.0+)](#database-setup-v050)
3. [Usage Examples](#usage-examples)
4. [Adaptive Rate Limiting (AIMD)](#adaptive-rate-limiting-aimd)
5. [Background Jobs](#background-jobs)
6. [UI Dashboard](#ui-dashboard)
7. [Full Configuration Reference](#full-configuration-reference)
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

## Database Setup (v0.5.0+)

Adaptive rate limiting, the Learning UI, and the dashboard's historical charts require a **PostgreSQL** database. Fixed-rate limiting (without adaptive features) only needs Redis — no database required.

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

## Adaptive Rate Limiting (AIMD)

When you **don't know** an API's exact rate limit — or the limit changes dynamically — use adaptive limits. The algorithm mirrors [TCP congestion control](https://en.wikipedia.org/wiki/Additive_increase/multiplicative_decrease):

1. Start at `initial_rate`
2. After `probe_window` seconds of success → increase by `increase_by`
3. On `error_classes` exception → multiply by `decrease_factor`
4. Wait `cooldown_after_decrease` before probing again
5. Over a few cycles the rate converges just below the real limit

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

That's it. On success the rate may gradually increase; on `TooManyRequests` it halves and backs off.

### Full setup (with header parsing)

```ruby
config.register_adaptive_limit(:external_api,
  initial_rate:          2,
  interval:              1,
  min_rate:              1,
  max_rate:              50,
  increase_by:           1,
  decrease_factor:       0.5,
  probe_window:          60,
  cooldown_after_decrease: 30,
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

### Manual header reporting

Classes using adaptive limits also get a `report_rate_limit_headers` instance helper:

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
# Clears the sliding window, any temporary override, AND the learned AIMD state.
# The rate reverts to initial_rate.
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

## Full Configuration Reference

### All global settings

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

### register_adaptive_limit (AIMD)

```ruby
config.register_adaptive_limit(:external_api,
  # ── Required ──
  initial_rate:          5,      # starting rate (requests per interval)
  interval:              1,      # window size in seconds

  # ── AIMD tuning ──
  min_rate:              1,      # floor after decreases
  max_rate:              50,     # ceiling (nil = no upper bound)
  increase_by:           1,      # additive increase on successful probe
  decrease_factor:       0.5,    # multiplicative decrease on error
  probe_window:          60,     # seconds of success before probing higher
  cooldown_after_decrease: 30,   # seconds to wait after a decrease

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
| `min_rate`                | No       | `1`     | Floor for the rate after decreases.                                             |
| `max_rate`                | No       | `nil`   | Ceiling for the rate. `nil` = no upper bound.                                   |
| `increase_by`             | No       | `1`     | How much to add on each successful probe.                                       |
| `decrease_factor`         | No       | `0.5`   | Multiplier applied on error (e.g. `0.5` = halve).                               |
| `probe_window`            | No       | `60`    | Seconds of success before attempting to increase.                               |
| `cooldown_after_decrease` | No       | `30`    | Seconds to wait after a decrease before probing again.                          |
| `error_classes`           | No       | `[]`    | Exception classes that trigger a decrease.                                      |
| `header_parser`           | No       | `nil`   | Lambda receiving the caught error; return `{ remaining:, reset: }` or nil.      |
| `response_parser`         | No       | `nil`   | Lambda receiving each successful return value; return `{ remaining:, reset: }`. |
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
