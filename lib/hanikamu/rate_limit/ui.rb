# frozen_string_literal: true

begin
  require "railties"
rescue LoadError
  nil
end

require "hanikamu/rate_limit/ui/engine" if defined?(Rails::Engine)
