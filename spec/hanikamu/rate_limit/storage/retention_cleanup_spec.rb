# frozen_string_literal: true

RSpec.describe Hanikamu::RateLimit::Storage::RetentionCleanup do
  before do
    pool_double = instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool)
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool_double)
    allow(pool_double).to receive(:with_connection).and_yield
  end

  describe ".run!" do
    let(:event_relation) { double("EventRelation") }
    let(:snapshot_relation) { double("SnapshotRelation") }

    before do
      allow(Hanikamu::RateLimit.config).to receive_messages(event_retention: 7.days, snapshot_retention: 30.days)
      allow(Hanikamu::RateLimit::Storage::CapturedEvent).to receive(:where).and_return(event_relation)
      allow(Hanikamu::RateLimit::Storage::RateSnapshot).to receive(:where).and_return(snapshot_relation)
      allow(event_relation).to receive(:delete_all).and_return(3)
      allow(snapshot_relation).to receive(:delete_all).and_return(5)
    end

    it "purges events older than event_retention" do
      freeze_time = Time.current
      allow(Time).to receive(:current).and_return(freeze_time)

      result = described_class.run!

      expect(Hanikamu::RateLimit::Storage::CapturedEvent)
        .to have_received(:where).with(created_at: ...(freeze_time - 7.days))
      expect(result[:events]).to eq(3)
    end

    it "purges snapshots older than snapshot_retention" do
      freeze_time = Time.current
      allow(Time).to receive(:current).and_return(freeze_time)

      result = described_class.run!

      expect(Hanikamu::RateLimit::Storage::RateSnapshot)
        .to have_received(:where).with(created_at: ...(freeze_time - 30.days))
      expect(result[:snapshots]).to eq(5)
    end

    it "returns a hash with event and snapshot counts" do
      result = described_class.run!

      expect(result).to eq(events: 3, snapshots: 5)
    end
  end
end
