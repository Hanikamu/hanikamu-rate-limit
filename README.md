# Hanikamu::RateLimit

[![ci](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml/badge.svg)](https://github.com/Hanikamu/hanikamu-rate-limit/actions/workflows/ci.yml)

Distributed, Redis-backed rate limiting with a sliding window algorithm. Works across processes and threads by coordinating through Redis.

## Table of Contents

1. [Why Hanikamu::RateLimit?](#why-hanikamurate-limit)
2. [Quick Start](#quick-start)
3. [Configuration](#configuration)
4. [Usage](#usage)
5. [Error Handling](#error-handling)
6. [Testing](#testing)
7. [Development](#development)
8. [License](#license)

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
- `register_limit`: define a named limit shared across classes.

Registered limit options:

- `rate` and `interval` (required).
- `check_interval`, `max_wait_time` (optional).

`key_prefix` is no longer configurable for registered limits; registry keys are derived from the registry name.

## Usage

Optional per-method overrides:

```ruby
limit_method :execute, rate: 5, interval: 1.0, check_interval: 0.1, max_wait_time: 3.0
```

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
