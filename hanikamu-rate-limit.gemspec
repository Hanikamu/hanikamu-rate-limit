# frozen_string_literal: true

$LOAD_PATH.push File.expand_path("lib", __dir__)

require "hanikamu/rate_limit/version"

Gem::Specification.new do |spec|
  spec.name = "hanikamu-rate-limit"
  spec.version = Hanikamu::RateLimit::VERSION
  spec.authors = ["Nicolai Seerup", "Alejandro Jimenez"]

  spec.summary = "Distributed Redis-backed rate limiting"
  spec.description = <<~DESC
    Ruby gem for distributed rate limiting backed by Redis. Provides a sliding-window limiter
    with configurable polling and maximum wait time, suitable for multi-process and multi-thread
    workloads.
  DESC
  spec.homepage = "https://github.com/Hanikamu/hanikamu-rate-limit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Hanikamu/hanikamu-rate-limit"
  spec.metadata["changelog_uri"] = "https://github.com/Hanikamu/hanikamu-rate-limit/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml starting_point/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-container", "~> 0.11"
  spec.add_dependency "redis", "~> 5.0"
end
