require "test_helper"

class RedbarkItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @redbark_item = redbark_items(:one)
    @importer = RedbarkItem::Importer.new(@redbark_item, redbark_provider: nil)
  end

  # Row 7: account details are the one thing in the sync a loan's rate
  # depends on, and the one thing a user can live without. A failure there must
  # not cost them balances or transactions.
  test "a failing account details fetch leaves the payload alone and does not raise" do
    redbark_account = redbark_accounts(:savings_account)
    family = redbark_account.redbark_item.family
    account = family.accounts.create!(
      name: "Mortgage", balance: 400_000, currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
    )
    redbark_account.ensure_account_provider!(account)
    redbark_account.update!(raw_account_details_payload: { "lendingRate" => "0.0625" })

    provider = mock
    provider.stubs(:list_connections).returns([])
    provider.stubs(:get_account_details).raises(Provider::Redbark::Error.new("boom", :server_error))
    importer = RedbarkItem::Importer.new(redbark_account.redbark_item, redbark_provider: provider)

    assert_nothing_raised do
      importer.send(:import_loan_account_details, [ redbark_account.reload ])
    end

    assert_equal({ "lendingRate" => "0.0625" }, redbark_account.reload.raw_account_details_payload,
                 "a failed fetch overwrote the details the last good sync stored")
  end

  # The stamp is the sync's clock, injected, not the importer's own reading of
  # it. Both phases of a sync have to agree on which day the snapshot belongs
  # to; see RedbarkItem::SyncerTest for why they must not read the clock twice.
  test "the injected clock stamps the snapshot, not the wall clock" do
    redbark_account = redbark_accounts(:savings_account)
    family = redbark_account.redbark_item.family
    account = family.accounts.create!(
      name: "Mortgage", balance: 400_000, currency: "AUD",
      accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
    )
    redbark_account.ensure_account_provider!(account)

    injected = Time.utc(2026, 9, 21, 23, 59, 30)
    provider = mock
    provider.stubs(:list_connections).returns([])
    provider.stubs(:get_account_details).returns([
      { accountId: redbark_account.redbark_account_id, lendingRate: "0.0675" }
    ])
    importer = RedbarkItem::Importer.new(
      redbark_account.redbark_item, redbark_provider: provider, fetched_at: injected
    )

    travel_to Time.utc(2026, 9, 22, 0, 0, 30) do
      importer.send(:import_loan_account_details, [ redbark_account.reload ])
    end

    assert_equal injected, redbark_account.reload.account_details_fetched_at.utc,
                 "the importer stamped its own reading of the clock instead of the sync's"
  end

  # The batch is rejected whole when one id is stale or of the wrong category,
  # so one bad account must not cost every other loan its rate. Mirrors
  # fetch_balances_with_fallback.
  #
  # Two DISTINCT accounts, because the fallback only engages for a batch of
  # more than one: with a single id there is nothing to demote to.
  test "a rejected batch falls back to one call per account" do
    first = redbark_accounts(:savings_account)
    item = first.redbark_item
    family = item.family
    second = item.redbark_accounts.create!(
      redbark_account_id: "rb_acc_loan_2", name: "Second loan", currency: "AUD"
    )

    [ first, second ].each_with_index do |redbark_account, index|
      account = family.accounts.create!(
        name: "Mortgage #{index}", balance: 400_000, currency: "AUD",
        accountable: Loan.new(rate_type: "variable", interest_rate: 6.25)
      )
      redbark_account.ensure_account_provider!(account)
    end

    provider = mock
    provider.stubs(:list_connections).returns([])
    provider.expects(:get_account_details)
            .with(account_ids: [ first.redbark_account_id, second.redbark_account_id ])
            .raises(Provider::Redbark::Error.new("stale id", :not_found))
    provider.expects(:get_account_details)
            .with(account_ids: [ first.redbark_account_id ])
            .returns([ { accountId: first.redbark_account_id, lendingRate: "0.0675" } ])
    provider.expects(:get_account_details)
            .with(account_ids: [ second.redbark_account_id ])
            .returns([])

    importer = RedbarkItem::Importer.new(item, redbark_provider: provider)
    importer.send(:import_loan_account_details, [ first.reload, second.reload ])

    assert_equal "0.0675", first.reload.raw_account_details_payload["lendingRate"],
                 "the account the retry could serve never got its details stored"
    assert_not_nil first.account_details_fetched_at, "a stored refresh was not stamped"
    assert_nil second.reload.raw_account_details_payload,
               "an account the retry could not serve was written anyway"
  end

  # Only loans: every other account type would cost a request per sync for a
  # field nothing reads.
  test "account details are not fetched when no linked account is a loan" do
    redbark_account = redbark_accounts(:savings_account)
    family = redbark_account.redbark_item.family
    account = family.accounts.create!(
      name: "Everyday", balance: 100, currency: "AUD", accountable: Depository.new
    )
    redbark_account.ensure_account_provider!(account)

    provider = mock
    provider.stubs(:list_connections).returns([])
    provider.expects(:get_account_details).never
    importer = RedbarkItem::Importer.new(redbark_account.redbark_item, redbark_provider: provider)

    importer.send(:import_loan_account_details, [ redbark_account.reload ])
  end

  test "merge_transactions keeps posted rows and refreshes by id" do
    existing = [ { "id" => "t1", "status" => "posted", "date" => "2026-07-01", "amount" => "-10.00" } ]
    fresh = [ { "id" => "t1", "status" => "posted", "date" => "2026-07-01", "amount" => "-12.00" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 6, 1))

    assert_equal 1, merged.size
    assert_equal "-12.00", merged.first["amount"]
  end

  test "merge_transactions prunes pending rows missing from the refetched window" do
    existing = [
      { "id" => "pend_1", "status" => "pending", "date" => "2026-07-10" },
      { "id" => "kept_posted", "status" => "posted", "date" => "2026-07-05" }
    ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))
    ids = merged.map { |t| t["id"] }

    assert_includes ids, "post_1"
    assert_includes ids, "kept_posted"
    assert_not_includes ids, "pend_1"
  end

  test "merge_transactions drops rows dated before the fetch window" do
    existing = [
      { "id" => "old_posted", "status" => "posted", "date" => "2026-05-01" },
      { "id" => "old_pending", "status" => "pending", "date" => "2026-06-15" },
      { "id" => "undated", "status" => "posted" }
    ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: Date.new(2026, 7, 1))

    assert_equal %w[post_1 undated], merged.map { |t| t["id"] }.sort
  end

  test "merge_transactions keeps everything when no window is given" do
    existing = [ { "id" => "old_posted", "status" => "posted", "date" => "2026-05-01" } ]
    fresh = [ { "id" => "post_1", "status" => "posted", "date" => "2026-07-10" } ]

    merged = @importer.send(:merge_transactions, existing, fresh, window_start: nil)

    assert_equal %w[old_posted post_1], merged.map { |t| t["id"] }.sort
  end
end
