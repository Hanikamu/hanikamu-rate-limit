# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::Storage::EventCapture do
  let(:registry_name) { :test_api }

  before do
    pool_double = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool_double)
    allow(pool_double).to receive(:with_connection).and_yield

    # Stub the inherit_classification lookup: where(...).where.not(...).order(...).pick(...)
    order_double = double("Order", pick: nil)
    where_not_double = double("WhereNot", order: order_double)
    where_chain = double("WhereChain", not: where_not_double)
    relation = double("Relation", where: where_chain)
    allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:where).and_return(relation)
  end

  describe ".capture_exception" do
    let(:error) { StandardError.new("rate limited") }

    it "creates a CapturedEvent with exception data" do
      event_double = instance_double(Hanikamu::RateLimit::Storage::CapturedEvent)
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:create!).and_return(event_double)

      described_class.capture_exception(registry_name, error)

      expect(Hanikamu::RateLimit::Storage::CapturedEvent).to have_received(:create!).with(
        hash_including(
          registry_name: "test_api",
          event_type: "exception",
          classification: "unclassified",
          exception_class: "StandardError",
          exception_message: "rate limited"
        )
      )
    end

    it "truncates long exception messages to 2000 chars" do
      long_error = StandardError.new("x" * 3000)
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:create!)

      described_class.capture_exception(registry_name, long_error)

      expect(Hanikamu::RateLimit::Storage::CapturedEvent).to have_received(:create!).with(
        hash_including(exception_message: a_string_matching(/\A.{1,2000}\z/))
      )
    end

    it "rescues and logs errors without re-raising" do
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { described_class.capture_exception(registry_name, error) }.not_to raise_error
    end
  end

  describe ".capture_response" do
    let(:response) do
      double("Response",
             status: 429,
             headers: { "X-RateLimit-Remaining" => "0" },
             body: "Too many requests",
             respond_to?: true)
    end
    let(:parsed) { { remaining: 0, reset: 30, reset_kind: :seconds } }

    before do
      allow(response).to receive(:respond_to?).with(:status).and_return(true)
      allow(response).to receive(:respond_to?).with(:headers).and_return(true)
      allow(response).to receive(:respond_to?).with(:body).and_return(true)
      allow(response).to receive(:respond_to?).with(:env).and_return(false)
      allow(response).to receive(:respond_to?).with(:[]).and_return(false)
    end

    it "creates a CapturedEvent with response data" do
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:create!)

      described_class.capture_response(registry_name, response, parsed)

      expect(Hanikamu::RateLimit::Storage::CapturedEvent).to have_received(:create!).with(
        hash_including(
          registry_name: "test_api",
          event_type: "response",
          classification: "unclassified",
          response_status: 429
        )
      )
    end
  end
end
