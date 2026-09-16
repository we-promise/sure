require "test_helper"

class SimplefinItem::RepairStaleLinkagesTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
  end

  test "does not hijack a linked account when an unlinked account merely shares its name (GH #2852)" do
    linked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-linked",
      name: "CHECKING (0001)",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )
    account = Account.create!(
      family: @family,
      name: "Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: account, provider: linked_sfa)

    unlinked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-unlinked-twin",
      name: "CHECKING (0001)",
      currency: "USD",
      current_balance: 999,
      account_type: "checking",
      raw_transactions_payload: [ { id: "txn-1", posted: 1_700_000_000, amount: "-10.00", description: "Coffee" } ]
    )

    # Both accounts are still present upstream (this is the reported failure mode:
    # two genuinely distinct accounts that happen to share a display name).
    @item.upstream_account_ids = [ linked_sfa.account_id, unlinked_sfa.account_id ]

    @item.send(:repair_stale_linkages, [ linked_sfa, unlinked_sfa ])

    linked_sfa.reload
    unlinked_sfa.reload

    assert_equal account, linked_sfa.current_account, "the correctly-linked account must keep its linkage"
    assert_nil unlinked_sfa.current_account, "the distinct twin must remain unlinked"
    assert_empty linked_sfa.raw_transactions_payload.to_a, "linked account's transactions must not be overwritten by its twin's"
  end

  test "still repairs a genuinely stale linkage when the old account_id is absent upstream" do
    stale_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-old-id",
      name: "Business",
      currency: "USD",
      current_balance: 100,
      account_type: "checking",
      raw_transactions_payload: [ { id: "old-txn", posted: 1_699_000_000, amount: "-5.00", description: "Old" } ]
    )
    account = Account.create!(
      family: @family,
      name: "Business Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: account, provider: stale_sfa)

    new_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-new-id",
      name: "Business",
      currency: "USD",
      current_balance: 288.41,
      account_type: "checking",
      raw_transactions_payload: [ { id: "new-txn", posted: 1_700_000_000, amount: "-10.00", description: "New" } ]
    )

    # Only the new account_id comes back upstream; the old one is genuinely gone
    # (e.g. the user deleted and re-added the institution in SimpleFIN).
    @item.upstream_account_ids = [ new_sfa.account_id ]

    @item.send(:repair_stale_linkages, [ stale_sfa, new_sfa ])

    new_sfa.reload
    stale_sfa.reload

    assert_equal account, new_sfa.current_account, "linkage should transfer to the new SimplefinAccount"
    assert_nil stale_sfa.current_account, "the old SimplefinAccount should be left orphaned"
    assert_equal 2, new_sfa.raw_transactions_payload.to_a.size, "transactions from both should be merged"
  end

  test "skips repair when upstream_account_ids is unavailable" do
    linked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-linked",
      name: "Business",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )
    account = Account.create!(
      family: @family,
      name: "Business Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: account, provider: linked_sfa)

    unlinked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-unlinked",
      name: "Business",
      currency: "USD",
      current_balance: 999,
      account_type: "checking",
      raw_transactions_payload: [ { id: "txn-1", posted: 1_700_000_000, amount: "-10.00", description: "Coffee" } ]
    )

    assert_nil @item.upstream_account_ids

    assert_difference "DebugLogEntry.count", 1 do
      @item.send(:repair_stale_linkages, [ linked_sfa, unlinked_sfa ])
    end

    assert_equal account, linked_sfa.reload.current_account
    assert_nil unlinked_sfa.reload.current_account

    entry = DebugLogEntry.last
    assert_equal "provider_sync_warning", entry.category
    assert_equal "simplefin", entry.provider_key
    assert_equal @family, entry.family
  end

  test "does not act on an ambiguous multi-way name match" do
    linked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-linked",
      name: "Checking",
      currency: "USD",
      current_balance: 100,
      account_type: "checking"
    )
    account = Account.create!(
      family: @family,
      name: "Checking",
      currency: "USD",
      balance: 100,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: account, provider: linked_sfa)

    other_linked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-other-linked",
      name: "Checking",
      currency: "USD",
      current_balance: 50,
      account_type: "checking"
    )
    other_account = Account.create!(
      family: @family,
      name: "Other Checking",
      currency: "USD",
      balance: 50,
      accountable: Depository.create!(subtype: :checking)
    )
    AccountProvider.create!(account: other_account, provider: other_linked_sfa)

    unlinked_sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-unlinked",
      name: "Checking",
      currency: "USD",
      current_balance: 999,
      account_type: "checking",
      raw_transactions_payload: [ { id: "txn-1", posted: 1_700_000_000, amount: "-10.00", description: "Coffee" } ]
    )

    # Neither linked account_id is present upstream, so both are candidates -> ambiguous.
    @item.upstream_account_ids = [ unlinked_sfa.account_id ]

    @item.send(:repair_stale_linkages, [ linked_sfa, other_linked_sfa, unlinked_sfa ])

    assert_equal account, linked_sfa.reload.current_account
    assert_equal other_account, other_linked_sfa.reload.current_account
    assert_nil unlinked_sfa.reload.current_account
  end
end
