require "test_helper"

class Ingestion::TransactionGroupCodecTest < ActiveSupport::TestCase
  test "group roundtrip keeps exact amounts dates typed evidence and unassigned removals" do
    original = group
    wire = JSON.parse(JSON.generate(Ingestion::TransactionGroupCodec.dump(original)))
    restored = Ingestion::TransactionGroupCodec.load(wire)
    assert_equal original.generation_id, restored.generation_id
    assert_equal original.start_cursor, restored.start_cursor
    assert_equal original.request_cursor, restored.request_cursor
    assert_equal original.next_cursor, restored.next_cursor
    assert restored.complete?
    assert_equal [ "unassigned-old-id" ], restored.unassigned_removed_ids
    assert_equal original.account_pages["remote-account"].records.first.attributes, restored.account_pages["remote-account"].records.first.attributes
    assert_equal original.evidence, restored.evidence
    refute restored.account_pages["remote-account"].complete?
  end

  test "a group is immutable without freezing caller input and inspect excludes financial data" do
    evidence = { "private" => [ "bank-description" ] }
    value = group(evidence: evidence)
    evidence["private"] << "later"
    assert_equal [ "bank-description" ], value.evidence["private"]
    assert_raises(FrozenError) { value.account_pages["other"] = value.account_pages.values.first }
    refute_includes value.inspect, "bank-description"
    refute_includes value.inspect, "private-cursor"
  end

  test "completed child pages cannot be confused with provisional captured changes" do
    page = Provider::AccountData::Page.new(records: [], complete: true)
    assert_raises(ArgumentError) { group(account_pages: { "remote-account" => page }) }
  end

  test "unknown envelope fields versions types and malformed decimals fail closed" do
    payload = Ingestion::TransactionGroupCodec.dump(group)
    [ payload.merge("version" => 2), payload.merge("version" => 1.0), payload.merge("extra" => true),
      payload.merge("kind" => "page"), payload.merge("account_pages" => []) ].each do |invalid|
      assert_raises(ArgumentError) { Ingestion::TransactionGroupCodec.load(invalid) }
    end
    invalid = payload.deep_dup
    invalid["evidence"] = [ "decimal", "NaN" ]
    assert_raises(ArgumentError) { Ingestion::TransactionGroupCodec.load(invalid) }
  end

  test "group pages contain only transactions and no independently advancing cursor" do
    holding = Ingestion::Record.holding(external_id: "h", currency: "USD", date: Date.new(2026, 9, 14), quantity: BigDecimal("1"), security: { ticker: "AAPL" })
    [ Provider::AccountData::Page.new(records: [ holding ], complete: false),
      Provider::AccountData::Page.new(records: [], complete: false, checkpoint_cursor: "unsafe") ].each do |page|
      assert_raises(ArgumentError) { group(account_pages: { "remote-account" => page }) }
    end
  end

  private
    def group(**options)
      record = Ingestion::Record.transaction(external_id: "transaction", name: "private-description", currency: "USD",
        date: Date.new(2026, 9, 14), amount: BigDecimal("12.1234567890123456789"), pending: false)
      page = Provider::AccountData::Page.new(records: [ record ], complete: false, removed_ids: [ "old-id" ], coverage: { "removal_policy" => "exact_external_id" })
      Provider::AccountData::TransactionGroup.new(**{ generation_id: "generation-1", start_cursor: "private-cursor0", request_cursor: "private-cursor1",
        next_cursor: "private-cursor2", complete: true, account_pages: { "remote-account" => page }, unassigned_removed_ids: [ "unassigned-old-id" ],
        evidence: { "raw" => BigDecimal("0.000000000000000001"), "type-tag-shaped" => [ "decimal", "not-a-decimal" ] } }.merge(options))
    end
end
