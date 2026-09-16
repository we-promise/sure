require "test_helper"

class Ingestion::TransactionGroupAssemblerTest < ActiveSupport::TestCase
  test "complete generations fold ordered revisions and removals before any financial application" do
    groups = [
      group(request: "committed", cursor: "page-1", complete: false, account: "account-a", records: [ record("changed", "5"), record("removed", "7") ]),
      group(request: "page-1", cursor: "terminal", complete: true, account: "account-a", records: [ record("changed", "8") ], removed: [ "removed" ])
    ]
    pages = Ingestion::TransactionGroupAssembler.new.assemble(groups)
    assert_equal [ "account-a" ], pages.keys
    page = pages.fetch("account-a")
    assert page.complete?
    assert_equal BigDecimal("8"), page.records.sole[:amount]
    assert_equal [ "removed" ], page.removed_ids
    assert_equal [ 0, 1 ], page.evidence.fetch("group_pages")
    assert_nil page.checkpoint_cursor
  end

  test "a provisional prefix and a different generation cannot be applied as complete" do
    first = group(request: "committed", cursor: "page-1", complete: false)
    assert_raises(Provider::AccountData::IncompletePage) { Ingestion::TransactionGroupAssembler.new.assemble([ first ]) }
    replacement = group(request: "page-1", cursor: "terminal", complete: true, generation: "different-generation")
    assert_raises(Provider::AccountData::InvalidResponse) { Ingestion::TransactionGroupAssembler.new.assemble([ first, replacement ]) }
  end

  test "unassigned removals require scoped identity evidence" do
    unassigned = group(request: "committed", cursor: "terminal", complete: true, unassigned: [ "removed" ])
    assert_raises(Ingestion::TransactionGroupAssembler::UnresolvedRemoval) do
      Ingestion::TransactionGroupAssembler.new.assemble([ unassigned ])
    end
    assert_raises(Ingestion::TransactionGroupAssembler::UnresolvedRemoval) do
      Ingestion::TransactionGroupAssembler.new(removal_accounts: { "removed" => %w[account-a account-b] }).assemble([ unassigned ])
    end
    result = Ingestion::TransactionGroupAssembler.new(removal_accounts: { "removed" => [ "account-a" ] }).assemble([ unassigned ])
    assert_equal [ "removed" ], result.fetch("account-a").removed_ids
  end

  test "unlinked account observations are retained and accounts remain separate" do
    first = group(request: "committed", cursor: "page-1", complete: false, account: "unlinked-account", records: [ record("one", "5") ])
    last = group(request: "page-1", cursor: "terminal", complete: true, account: "linked-account", records: [ record("two", "7") ])
    result = Ingestion::TransactionGroupAssembler.new.assemble([ first, last ])
    assert_equal %w[linked-account unlinked-account], result.keys
    assert_equal "one", result.fetch("unlinked-account").records.sole[:external_id]
  end

  test "missing and repeating pagination edges cannot fabricate a complete generation" do
    first = group(request: "committed", cursor: "page-1", complete: false)
    skipped = group(request: "missing-page", cursor: "terminal", complete: true)
    assert_raises(Provider::AccountData::InvalidResponse) { Ingestion::TransactionGroupAssembler.new.assemble([ first, skipped ]) }
    assert_raises(ArgumentError) { group(request: "page-1", cursor: "page-1", complete: false) }
    looping = group(request: "page-1", cursor: "page-2", complete: false)
    repeated = group(request: "page-1", cursor: "terminal", complete: true)
    assert_raises(Provider::AccountData::InvalidResponse) { Ingestion::TransactionGroupAssembler.new.assemble([ first, looping, repeated ]) }
  end

  test "legacy folding preserves added precedence and applies removals after every page" do
    added = record("changed", "5", change_type: "added")
    modified = record("changed", "8", change_type: "modified")
    readded = record("removed", "9", change_type: "added")
    first = group(request: "committed", cursor: "page-1", complete: false, records: [ added ], removed: [ "removed" ], policy: "modified_added_removed")
    last = group(request: "page-1", cursor: "terminal", complete: true, records: [ modified, readded ], policy: "modified_added_removed")
    page = Ingestion::TransactionGroupAssembler.new.assemble([ first, last ]).fetch("account-a")
    assert_equal BigDecimal("5"), page.records.sole[:amount]
    assert_equal [ "removed" ], page.removed_ids
    assert_equal false, page.coverage.fetch("pending_absence_authoritative")
    assert_equal "modified_added_removed", page.evidence.fetch("folding_policy")
    assert_equal "modified_added_removed", Ingestion::TransactionGroupCodec.load(Ingestion::TransactionGroupCodec.dump(first)).folding_policy
  end

  test "folding policy cannot change inside an otherwise continuous generation" do
    first = group(request: "committed", cursor: "page-1", complete: false)
    last = group(request: "page-1", cursor: "terminal", complete: true, policy: "modified_added_removed")
    assert_raises(Provider::AccountData::InvalidResponse) { Ingestion::TransactionGroupAssembler.new.assemble([ first, last ]) }
  end

  private
    def record(id, amount, **metadata)
      Ingestion::Record.transaction(external_id: id, name: "Transaction", date: Date.current, currency: "USD", amount: BigDecimal(amount), pending: false, metadata: metadata)
    end

    def group(request:, cursor:, complete:, account: "account-a", records: [], removed: [], unassigned: [], generation: "generation", policy: "page_ordered")
      page = Provider::AccountData::Page.new(records: records, removed_ids: removed, complete: false)
      Provider::AccountData::TransactionGroup.new(generation_id: generation, start_cursor: "committed", request_cursor: request,
        next_cursor: cursor, complete: complete, account_pages: { account => page }, unassigned_removed_ids: unassigned, evidence: {}, folding_policy: policy)
    end
end
