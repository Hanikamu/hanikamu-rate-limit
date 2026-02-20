# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::JobRetry do
  let(:redis_url) { ENV.fetch("REDIS_URL", "redis://localhost:6379/15") }
  # Minimal ActiveJob-like base class for testing
  let(:fake_job_base) do
    Class.new do
      class << self
        def rescue_from(exception_class, &block)
          @rescue_handlers ||= []
          @rescue_handlers << [exception_class, block]
        end

        def rescue_handlers
          @rescue_handlers || []
        end
      end

      attr_accessor :executions

      def initialize
        @executions = 0
      end

      def retry_job(wait:)
        @retried_with_wait = wait
      end

      attr_reader :retried_with_wait

      def perform(*args, **kwargs)
        # no-op, overridden by subclasses
      end

      def handle_exception(exception)
        handler = self.class.rescue_handlers.find { |klass, _| exception.is_a?(klass) }
        raise exception unless handler

        instance_exec(exception, &handler[1])
      end
    end
  end

  # Minimal Sidekiq-like base class for testing
  let(:fake_sidekiq_base) do
    Class.new do
      class << self
        def sidekiq_options(opts = {})
          @sidekiq_options = (@sidekiq_options || {}).merge(opts)
        end

        def stored_sidekiq_options
          @sidekiq_options || {}
        end

        def sidekiq_retry_in(&block)
          @sidekiq_retry_in_block = block
        end

        def stored_retry_in_block
          @sidekiq_retry_in_block
        end
      end

      def perform(*, **)
        # no-op, overridden by subclasses
      end
    end
  end
  let(:redis) { Redis.new(url: redis_url) }

  before do
    Hanikamu::RateLimit.configure do |config|
      config.redis_url = redis_url
      config.max_wait_time = 2.0
      config.check_interval = 0.5
      config.wait_strategy = :sleep
    end
    redis.flushdb
  end

  after do
    redis.flushdb
  end

  describe ".rate_limit_retry" do
    it "registers a rescue_from handler for RateLimitError" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry
      end

      expect(job_class.rescue_handlers.size).to eq(1)
      expect(job_class.rescue_handlers.first[0]).to eq(Hanikamu::RateLimit::RateLimitError)
    end

    it "retries with the exception's retry_after value" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry
      end

      job = job_class.new
      job.executions = 0

      error = Hanikamu::RateLimit::RateLimitError.new("Rate limited", retry_after: 3.5)
      job.handle_exception(error)

      expect(job.retried_with_wait).to eq(3.5)
    end

    it "uses fallback_wait when retry_after is nil" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry fallback_wait: 10
      end

      job = job_class.new
      job.executions = 0

      error = Hanikamu::RateLimit::RateLimitError.new("Rate limited", retry_after: nil)
      job.handle_exception(error)

      expect(job.retried_with_wait).to eq(10)
    end

    it "re-raises when attempts are exhausted" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry attempts: 3
      end

      job = job_class.new
      job.executions = 5

      error = Hanikamu::RateLimit::RateLimitError.new("Rate limited", retry_after: 1.0)

      expect { job.handle_exception(error) }.to raise_error(Hanikamu::RateLimit::RateLimitError)
    end

    it "retries indefinitely with attempts: :unlimited" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry attempts: :unlimited
      end

      job = job_class.new
      job.executions = 999

      error = Hanikamu::RateLimit::RateLimitError.new("Rate limited", retry_after: 2.0)
      job.handle_exception(error)

      expect(job.retried_with_wait).to eq(2.0)
    end

    it "sets wait strategy to :raise during perform" do
      captured_strategy = nil

      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry

        define_method(:perform) do |*, **|
          captured_strategy = Hanikamu::RateLimit.current_wait_strategy
        end
      end

      job = job_class.new
      job.perform

      expect(captured_strategy).to eq(:raise)
    end

    it "restores previous wait strategy after perform" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry

        define_method(:perform) do |*, **|
          # no-op
        end
      end

      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil

      job = job_class.new
      job.perform

      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    it "restores previous wait strategy even if perform raises" do
      job_class = Class.new(fake_job_base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry

        define_method(:perform) do |*, **|
          raise "boom"
        end
      end

      job = job_class.new

      expect { job.perform }.to raise_error(RuntimeError, "boom")
      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    context "with jitter enabled" do
      before do
        Hanikamu::RateLimit.configure { |c| c.jitter = 0.2 }
      end

      after do
        Hanikamu::RateLimit.configure { |c| c.jitter = 0.0 }
      end

      it "passes retry_after through without applying additional jitter" do
        job_class = Class.new(fake_job_base) do
          extend Hanikamu::RateLimit::JobRetry

          rate_limit_retry
        end

        # retry_after is already jittered by RateQueue#raise_if_strategy!
        error = Hanikamu::RateLimit::RateLimitError.new("Rate limited", retry_after: 5.7)

        job = job_class.new
        job.executions = 0
        job.handle_exception(error)

        expect(job.retried_with_wait).to eq(5.7)
      end
    end

    context "with invalid options" do
      it "raises ArgumentError when attempts is not :unlimited or a positive Integer" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry attempts: :foo
          end
        end.to raise_error(ArgumentError, /attempts must be :unlimited or a positive Integer/)
      end

      it "raises ArgumentError when attempts is zero" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry attempts: 0
          end
        end.to raise_error(ArgumentError, /attempts must be :unlimited or a positive Integer/)
      end

      it "raises ArgumentError when attempts is negative" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry attempts: -1
          end
        end.to raise_error(ArgumentError, /attempts must be :unlimited or a positive Integer/)
      end

      it "raises ArgumentError when fallback_wait is nil" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry fallback_wait: nil
          end
        end.to raise_error(ArgumentError, /fallback_wait must be a non-negative Numeric/)
      end

      it "raises ArgumentError when fallback_wait is negative" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry fallback_wait: -1
          end
        end.to raise_error(ArgumentError, /fallback_wait must be a non-negative Numeric/)
      end

      it "raises ArgumentError for an invalid worker option" do
        expect do
          Class.new(fake_job_base) do
            extend Hanikamu::RateLimit::JobRetry

            rate_limit_retry worker: :resque
          end
        end.to raise_error(ArgumentError, /worker must be one of/)
      end
    end
  end

  describe ".rate_limit_retry with worker: :sidekiq" do
    around do |example|
      # Stub Sidekiq module for the duration of each test
      stub_sidekiq("8.1.0") { example.run }
    end

    it "sets sidekiq_options retry to the given attempts" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq, attempts: 10
      end

      expect(job_class.stored_sidekiq_options[:retry]).to eq(9)
    end

    it "sets a large retry count for attempts: :unlimited" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq, attempts: :unlimited
      end

      expect(job_class.stored_sidekiq_options[:retry]).to eq(described_class::SIDEKIQ_UNLIMITED_RETRIES)
    end

    it "registers a sidekiq_retry_in block" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq
      end

      expect(job_class.stored_retry_in_block).not_to be_nil
    end

    it "returns retry_after for RateLimitError in the retry_in block" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq
      end

      error = Hanikamu::RateLimit::RateLimitError.new("limited", retry_after: 7.5)
      result = job_class.stored_retry_in_block.call(1, error)

      expect(result).to eq(7.5)
    end

    it "returns fallback_wait when retry_after is nil" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq, fallback_wait: 12
      end

      error = Hanikamu::RateLimit::RateLimitError.new("limited", retry_after: nil)
      result = job_class.stored_retry_in_block.call(1, error)

      expect(result).to eq(12)
    end

    it "returns nil for non-RateLimitError exceptions (uses default backoff)" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq
      end

      error = RuntimeError.new("something else")
      result = job_class.stored_retry_in_block.call(1, error)

      expect(result).to be_nil
    end

    it "sets wait strategy to :raise during perform" do
      captured_strategy = nil

      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq

        define_method(:perform) do |*, **|
          captured_strategy = Hanikamu::RateLimit.current_wait_strategy
        end
      end

      job_class.new.perform

      expect(captured_strategy).to eq(:raise)
    end

    it "restores wait strategy after perform" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq

        define_method(:perform) do |*, **|
          # no-op
        end
      end

      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil

      job_class.new.perform

      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    it "restores wait strategy even if perform raises" do
      base = fake_sidekiq_base
      job_class = Class.new(base) do
        extend Hanikamu::RateLimit::JobRetry

        rate_limit_retry worker: :sidekiq

        define_method(:perform) do |*, **|
          raise "boom"
        end
      end

      expect { job_class.new.perform }.to raise_error(RuntimeError, "boom")
      expect(Hanikamu::RateLimit.current_wait_strategy).to be_nil
    end

    context "with Sidekiq version too low" do
      it "raises LoadError for sidekiq < 8.1" do
        stub_sidekiq("7.3.0") do
          expect do
            base = fake_sidekiq_base
            Class.new(base) do
              extend Hanikamu::RateLimit::JobRetry

              rate_limit_retry worker: :sidekiq
            end
          end.to raise_error(LoadError, /requires sidekiq >= 8.1/)
        end
      end
    end

    context "without Sidekiq loaded" do
      it "raises LoadError when Sidekiq is not defined" do
        # Ensure no Sidekiq constant exists
        hide_sidekiq do
          expect do
            base = fake_sidekiq_base
            Class.new(base) do
              extend Hanikamu::RateLimit::JobRetry

              rate_limit_retry worker: :sidekiq
            end
          end.to raise_error(LoadError, /requires the sidekiq gem/)
        end
      end
    end

    context "when host class lacks Sidekiq DSL methods" do
      it "raises ArgumentError with a helpful message" do
        stub_sidekiq("8.1.0") do
          expect do
            # Plain class without include Sidekiq::Job — no sidekiq_options or sidekiq_retry_in
            Class.new do
              extend Hanikamu::RateLimit::JobRetry

              rate_limit_retry worker: :sidekiq
            end
          end.to raise_error(ArgumentError, /include Sidekiq::Job/)
        end
      end
    end
  end

  private

  # Temporarily defines a fake ::Sidekiq module with the given version.
  def stub_sidekiq(version)
    already_defined = defined?(Sidekiq)
    old_sidekiq = Sidekiq if already_defined

    Object.send(:remove_const, :Sidekiq) if already_defined
    fake = Module.new
    fake.const_set(:VERSION, version)
    Object.const_set(:Sidekiq, fake)

    yield
  ensure
    Object.send(:remove_const, :Sidekiq) if Object.const_defined?(:Sidekiq)
    Object.const_set(:Sidekiq, old_sidekiq) if already_defined
  end

  # Temporarily hides ::Sidekiq so it appears unloaded.
  def hide_sidekiq
    already_defined = defined?(Sidekiq)
    old_sidekiq = Sidekiq if already_defined
    Object.send(:remove_const, :Sidekiq) if already_defined

    yield
  ensure
    Object.send(:remove_const, :Sidekiq) if Object.const_defined?(:Sidekiq)
    Object.const_set(:Sidekiq, old_sidekiq) if already_defined
  end
end
