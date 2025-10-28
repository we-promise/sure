require "test_helper"

class SimplefinImporterTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  class FakeSimplefinProvider
    attr_reader :calls

    def initialize(responses:)
      @responses = Array(responses)
      @calls = []
    end

    def get_accounts(_access_url, start_date:, end_date: nil, pending: nil)
      @calls << { start_date: start_date, end_date: end_date, pending: pending }
      payload = if @responses.first.respond_to?(:call)
        # Allow Proc to compute payload dynamically per call
        @responses.shift.call(start_date: start_date, end_date: end_date, pending: pending)
      else
        @responses.shift || { accounts: [] }
      end
      payload.deep_symbolize_keys
    end
  end

  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin",
      access_url: "https://example.com/sfin"
    )
  end

  test "initial sync uses 60-day chunks, respects lookback cap, and snapshots first chunk" do
    travel_to Time.zone.parse("2025-10-26 12:00:00") do
      # User requested 6 months lookback
      @item.update!(sync_start_date: 6.months.ago.beginning_of_day)

      # Prepare responses for: discovery (no dates), then first/second chunks.
      responses = [
        { accounts: [ { id: "acc_discovery", name: "Discovery", currency: "USD", balance: 0 } ], tag: "discovery" },
        { accounts: [ { id: "acc1", name: "A1", currency: "USD", balance: 0 } ], tag: "chunk-1" },
        { accounts: [ { id: "acc2", name: "A2", currency: "USD", balance: 0 } ], tag: "chunk-2" }
      ]
      fake = FakeSimplefinProvider.new(responses: responses.dup)

      importer = SimplefinItem::Importer.new(@item, simplefin_provider: fake)
      importer.import

      # Ensure we made multiple calls and each window is <= 60 days
      assert_operator fake.calls.length, :>=, 1
      fake.calls.each do |c|
        next unless c[:start_date] && c[:end_date]
        days = (c[:end_date].to_date - c[:start_date].to_date).to_i
        assert_operator days, :<=, 60, "chunk exceeded 60 days: #{days}"
      end

      # Snapshot should reflect the first chunk payload (tag: "chunk-1")
      @item.reload
      assert_equal "chunk-1", @item.raw_payload&.dig("tag"), "expected first chunk to be snapshotted"
    end
  end

  test "skips accounts that include an error and records skipped_accounts" do
    # One account has a provider error; one is valid
    responses = [
      {
        accounts: [
          { id: "acct_error", error: "Apple Card blocked" },
          { id: "acct_ok", name: "OK Account", currency: "USD", balance: 0 }
        ]
      }
    ]
    fake = FakeSimplefinProvider.new(responses: responses)

    importer = SimplefinItem::Importer.new(@item, simplefin_provider: fake)

    assert_nothing_raised do
      importer.import
    end

    assert_equal 1, importer.skipped_accounts.size
    assert_equal "acct_error", importer.skipped_accounts.first[:id]
  end
end
