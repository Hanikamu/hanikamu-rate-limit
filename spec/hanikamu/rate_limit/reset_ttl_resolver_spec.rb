# frozen_string_literal: true

require "spec_helper"

RSpec.describe Hanikamu::RateLimit::ResetTtlResolver do
  describe ".resolve" do
    it "dispatches to the correct resolver" do
      expect(described_class.resolve(30, :seconds)).to eq(30)
    end

    it "raises ArgumentError for an invalid reset_kind" do
      expect { described_class.resolve(30, :bogus) }
        .to raise_error(ArgumentError, /Invalid reset_kind: :bogus/)
    end

    it "includes valid options in the error message" do
      expect { described_class.resolve(30, :bogus) }
        .to raise_error(ArgumentError, /seconds, unix, datetime/)
    end
  end

  describe ".resolve_seconds" do
    it "returns the integer value directly" do
      expect(described_class.resolve_seconds(30)).to eq(30)
    end

    it "returns 0 for zero" do
      expect(described_class.resolve_seconds(0)).to eq(0)
    end

    it "returns nil for a non-numeric string" do
      expect(described_class.resolve_seconds("abc")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.resolve_seconds(nil)).to be_nil
    end

    it "unwraps a single-element array" do
      expect(described_class.resolve_seconds(["45"])).to eq(45)
    end

    it "unwraps a single-element array with an integer" do
      expect(described_class.resolve_seconds([60])).to eq(60)
    end

    it "returns the value at exactly MAX_SECONDS_TTL" do
      expect(described_class.resolve_seconds(86_400)).to eq(86_400)
    end

    it "raises ArgumentError when value exceeds MAX_SECONDS_TTL" do
      expect { described_class.resolve_seconds(86_401) }
        .to raise_error(ArgumentError, /exceeds MAX_SECONDS_TTL/)
    end

    it "suggests :unix in the overflow error message" do
      expect { described_class.resolve_seconds(1_718_450_000) }
        .to raise_error(ArgumentError, /Use reset_kind: :unix/)
    end
  end

  describe ".resolve_unix" do
    it "returns positive TTL for a future timestamp" do
      future = Time.now.to_i + 120
      result = described_class.resolve_unix(future)
      expect(result).to be_within(2).of(120)
    end

    it "returns negative TTL for a past timestamp" do
      past = Time.now.to_i - 60
      result = described_class.resolve_unix(past)
      expect(result).to be < 0
    end

    it "unwraps a single-element string array" do
      future = (Time.now.to_i + 60).to_s
      result = described_class.resolve_unix([future])
      expect(result).to be_within(2).of(60)
    end

    it "returns nil for a non-numeric string" do
      expect(described_class.resolve_unix("not-a-timestamp")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.resolve_unix(nil)).to be_nil
    end

    it "returns nil for an empty array" do
      expect(described_class.resolve_unix([])).to be_nil
    end
  end

  describe ".resolve_datetime" do
    it "returns positive TTL for a future Time" do
      future = Time.now + 90
      result = described_class.resolve_datetime(future)
      expect(result).to be_within(2).of(90)
    end

    it "returns positive TTL for a future DateTime" do
      future = DateTime.parse((Time.now + 90).to_s)
      result = described_class.resolve_datetime(future)
      expect(result).to be_within(2).of(90)
    end

    it "returns negative TTL for a past Time" do
      past = Time.now - 30
      result = described_class.resolve_datetime(past)
      expect(result).to be < 0
    end

    it "returns nil for nil" do
      expect(described_class.resolve_datetime(nil)).to be_nil
    end

    it "returns nil for a String" do
      expect(described_class.resolve_datetime("2026-01-01T00:00:00Z")).to be_nil
    end

    it "returns nil for an Integer" do
      expect(described_class.resolve_datetime(Time.now.to_i + 60)).to be_nil
    end

    it "returns nil for an Array" do
      expect(described_class.resolve_datetime([Time.now + 60])).to be_nil
    end
  end

  describe ".validate_reset_kind!" do
    %i[seconds unix datetime].each do |kind|
      it "accepts :#{kind}" do
        expect { described_class.validate_reset_kind!(kind) }.not_to raise_error
      end
    end

    it "rejects a string version of a valid kind" do
      expect { described_class.validate_reset_kind!("seconds") }
        .to raise_error(ArgumentError)
    end

    it "rejects nil" do
      expect { described_class.validate_reset_kind!(nil) }
        .to raise_error(ArgumentError)
    end
  end
end
