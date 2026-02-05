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
gem "hanikamu-rate-limit", "~> 0.1.0"
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
- `key_prefix` (optional) to force a shared Redis key; defaults to a registry-based prefix.

## Usage

Optional per-method overrides:

```ruby
limit_method :execute, rate: 5, interval: 1.0, check_interval: 0.1, max_wait_time: 3.0
```

Use a registered limit shared across classes:

```ruby
class SaxoClient
  extend Hanikamu::RateLimit::Mixin

  limit_with :execute, registry: :external_api

  def execute
    # work
  end
end
```

Registry precedence (highest to lowest):

1. Per-method overrides passed to `limit_with`.
2. Registered limit options.
3. Global defaults from `Hanikamu::RateLimit.configure`.

Reset method is generated automatically:

```ruby
MyService.reset_execute_limit!
```

## Error Handling

If Redis is unavailable, `RateQueue#shift` logs a warning and returns `nil`.

## Testing

```bash
bundle exec rspec
```

## Development

```bash
bundle exec rake
```

## License

MIT
