require "test_helper"

class Ingestion::ActivityGroupTest < ActiveSupport::TestCase
  test "activity envelopes preserve exact typed records and declare their resource" do
    original = group(records: [ activity("event", "0.000000000000000001") ], complete: true)
    restored = Ingestion::TransactionGroupCodec.load(JSON.parse(JSON.generate(Ingestion::TransactionGroupCodec.dump(original))))

    assert_equal "activities", restored.resource
    assert_equal "first_observation", restored.folding_policy
    assert_equal original.account_pages.fetch("portfolio").records.sole.attributes,
      restored.account_pages.fetch("portfolio").records.sole.attributes
    assert restored.frozen?
    assert restored.resource.frozen?
    assert_equal original.evidence, restored.evidence
    refute_includes restored.inspect, "private detail"
  end

  test "legacy transaction envelopes without resource or folding policy retain their original semantics" do
    record = transaction("transaction", "10")
    original = group(resource: "transactions", folding_policy: "page_ordered", records: [ record ], complete: true)
    payload = Ingestion::TransactionGroupCodec.dump(original).except("resource", "folding_policy")
    restored = Ingestion::TransactionGroupCodec.load(payload)

    assert_equal "transactions", restored.resource
    assert_equal "page_ordered", restored.folding_policy
    assert_equal record.attributes, restored.account_pages.fetch("portfolio").records.sole.attributes
    page = Ingestion::TransactionGroupAssembler.new.assemble([ restored ]).fetch("portfolio")
    assert_equal "exact_external_id", page.coverage.fetch("removal_policy")
  end

  test "activity groups reject removals transaction records and incompatible folding policies" do
    invalid = [
      { removed: [ "removed" ] }, { unassigned_removed_ids: [ "removed" ] },
      { records: [ transaction("wrong-resource", "10") ] },
      { coverage: { "removal_policy" => "exact_external_id" } },
      { coverage: { "pending_absence_authoritative" => true } },
      { folding_policy: "modified_added_removed" }, { folding_policy: "page_ordered" },
      { resource: "transactions", records: [ transaction("transaction", "10") ] },
      { resource: "holdings" }
    ]
    invalid.each { |options| assert_raises(ArgumentError) { group(**options) } }
  end

  test "first source identity wins across topic pages without matching equal financial values" do
    first = group(records: [ activity("shared", "10"), activity("same-value-other-id", "10"), activity("shared", "20") ])
    last = group(request_cursor: "next", next_cursor: "terminal", complete: true,
      records: [ activity("shared", "30"), activity("new", "40") ])
    page = Ingestion::TransactionGroupAssembler.new.assemble([ first, last ]).fetch("portfolio")

    assert_equal %w[shared same-value-other-id new], page.records.map { |record| record[:external_id] }
    assert_equal [ BigDecimal("10"), BigDecimal("10"), BigDecimal("40") ], page.records.map { |record| record[:amount] }
    assert_equal [ 0, 1 ], page.evidence.fetch("group_pages")
    assert_equal "activities", page.evidence.fetch("resource")
    assert_equal({ "pending_absence_authoritative" => false }, page.coverage)
    assert_empty page.removed_ids
    assert page.complete?
    assert_equal "delta", page.mode
    assert_nil page.checkpoint_cursor
  end

  test "first observations are scoped to each account and empty staging groups are retained in the chain" do
    initial = group(account_pages: {})
    portfolio = group(request_cursor: "next", next_cursor: "last", records: [ activity("shared", "10") ])
    cash = group(request_cursor: "last", next_cursor: "terminal", account: "cash", complete: true, records: [ activity("shared", "20") ])
    pages = Ingestion::TransactionGroupAssembler.new.assemble([ initial, portfolio, cash ])

    assert_equal %w[cash portfolio], pages.keys
    assert_equal BigDecimal("10"), pages.fetch("portfolio").records.sole[:amount]
    assert_equal BigDecimal("20"), pages.fetch("cash").records.sole[:amount]
    assert_equal [ 1 ], pages.fetch("portfolio").evidence.fetch("group_pages")
    assert_equal [ 2 ], pages.fetch("cash").evidence.fetch("group_pages")
  end

  test "an activity prefix or mixed resource chain cannot become a completed change set" do
    first = group(records: [ activity("first", "10") ])
    assert_raises(Provider::AccountData::IncompletePage) { Ingestion::TransactionGroupAssembler.new.assemble([ first ]) }
    transaction_group = group(resource: "transactions", folding_policy: "page_ordered", request_cursor: "next",
      next_cursor: "terminal", complete: true, records: [ transaction("second", "20") ])
    assert_raises(Provider::AccountData::InvalidResponse) do
      Ingestion::TransactionGroupAssembler.new.assemble([ first, transaction_group ])
    end
  end

  private
    def activity(id, amount)
      Ingestion::Record.activity(external_id: id, name: "private detail", currency: "EUR", date: Date.new(2026, 9, 15),
        amount: BigDecimal(amount), activity_type: "dividend")
    end

    def transaction(id, amount)
      Ingestion::Record.transaction(external_id: id, name: "Transaction", currency: "EUR", date: Date.new(2026, 9, 15),
        amount: BigDecimal(amount), pending: false)
    end

    def group(records: [], removed: [], coverage: {}, account: "portfolio", **options)
      page = Provider::AccountData::Page.new(records: records, removed_ids: removed, coverage: coverage, complete: false)
      Provider::AccountData::TransactionGroup.new(**{
        resource: "activities", folding_policy: "first_observation", generation_id: "generation", start_cursor: "committed",
        request_cursor: "committed", next_cursor: "next", complete: false, account_pages: { account => page },
        unassigned_removed_ids: [], evidence: { "detail" => "private detail" }
      }.merge(options))
    end
end
