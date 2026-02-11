---
applyTo: "**"
---

# Hanikamu Rate Limit — Development Instructions

## Running commands

Always run specs, linting, and other development commands **inside Docker** using the Makefile targets. Never run `bundle exec` directly on the host.

Always verify changes by running `make rspec` and report the result.

### Available Make commands

| Command        | Purpose                                      |
| -------------- | -------------------------------------------- |
| `make build`   | Build the Docker image                       |
| `make bundle`  | Install gems and rebuild the image           |
| `make rspec`   | Run the full test suite (`bundle exec rspec`) |
| `make cops`    | Run RuboCop with auto-correct (`-A`)         |
| `make console` | Open an IRB console with the gem loaded      |
| `make shell`   | Open a bash shell inside the container       |

### Examples

```bash
# Run tests
make rspec

# Fix lint issues
make cops

# Rebuild after Gemfile changes
make bundle
```

### Why Docker?

The project depends on Redis for integration tests. `docker-compose` starts a Redis service automatically, so there is no need to install or manage Redis on the host. Running commands outside Docker will fail with missing gems or no Redis connection.
