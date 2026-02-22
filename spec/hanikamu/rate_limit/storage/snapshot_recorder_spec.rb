# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::Storage::SnapshotRecorder do
  before do
    pool_double = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool_double)
    allow(pool_double).to receive(:with_connection).and_yield
  end

  describe ".tick!" do
    let(:state_double) do
      instance_double(
        Hanikamu::RateLimit::AdaptiveState,
        state: { current_rate: 50, cooldown_active: false },
        config: { min_rate: 10, max_rate: 100 }
      )
    end

    before do
      allow(Hanikamu::RateLimit).to receive(:adaptive_states).and_return({ api: state_double })
      allow(Hanikamu::RateLimit.config).to receive(:snapshot_interval).and_return(30)
    end

    it "records snapshots for adaptive limits when interval has elapsed" do
      scope_double = double("scope")
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:for_registry).and_return(scope_double)
      allow(scope_double).to receive_messages(order: scope_double, pick: nil) # no previous snapshot
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!)

      described_class.tick!

      expect(Hanikamu::RateLimit::Storage::RateSnapshot).to have_received(:create!).with(
        hash_including(
          registry_name: "api",
          rate: 50,
          min_rate: 10,
          max_rate: 100,
          cooldown_active: false
        )
      )
    end

    it "skips recording when interval has not elapsed" do
      scope_double = double("scope")
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:for_registry).and_return(scope_double)
      allow(scope_double).to receive_messages(order: scope_double, pick: Time.now) # just recorded
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!)

      described_class.tick!

      expect(Hanikamu::RateLimit::Storage::RateSnapshot).not_to have_received(:create!)
    end
  end

  describe ".record!" do
    let(:state_double) do
      instance_double(
        Hanikamu::RateLimit::AdaptiveState,
        state: { current_rate: 42, cooldown_active: true },
        config: { min_rate: 5, max_rate: 80 }
      )
    end

    it "creates a snapshot record" do
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!)

      described_class.record!(:my_api, state_double)

      expect(Hanikamu::RateLimit::Storage::RateSnapshot).to have_received(:create!).with(
        registry_name: "my_api",
        rate: 42,
        min_rate: 5,
        max_rate: 80,
        cooldown_active: true
      )
    end

    it "rescues errors without re-raising" do
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { described_class.record!(:my_api, state_double) }.not_to raise_error
    end
  end
end
