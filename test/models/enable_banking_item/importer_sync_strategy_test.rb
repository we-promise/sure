require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterSyncStrategyTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "AT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      sync_start_date: 3.months.ago.to_date,
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
    @enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
  end

  test "determine_sync_start_date returns nil for an initial sync when sync_strategy is longest" do
    @enable_banking_item.update!(sync_strategy: "longest")

    assert_nil @importer.send(:determine_sync_start_date, @enable_banking_account)
  end

  test "determine_sync_start_date still returns the configured date for an initial sync when sync_strategy is date" do
    configured_date = 5.months.ago.to_date
    @enable_banking_item.update!(sync_strategy: "date", sync_start_date: configured_date)

    assert_equal configured_date, @importer.send(:determine_sync_start_date, @enable_banking_account)
  end

  test "determine_sync_start_date's incremental branch is unaffected by sync_strategy" do
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "1" } ])
    @enable_banking_item.stubs(:last_synced_at).returns(10.days.ago)

    date_result = @importer.send(:determine_sync_start_date, @enable_banking_account)
    @enable_banking_item.update!(sync_strategy: "longest")
    longest_result = @importer.send(:determine_sync_start_date, @enable_banking_account)

    assert_equal 10.days.ago.to_date - 7.days, date_result
    assert_equal date_result, longest_result
  end

  test "allow_longest_retry_for is true only for an initial sync with the date strategy" do
    assert @importer.send(:allow_longest_retry_for, @enable_banking_account)

    @enable_banking_item.update!(sync_strategy: "longest")
    assert_not @importer.send(:allow_longest_retry_for, @enable_banking_account)

    @enable_banking_item.update!(sync_strategy: "date")
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "1" } ])
    assert_not @importer.send(:allow_longest_retry_for, @enable_banking_account)
  end

  test "fetch_and_store_transactions requests strategy longest for BOOK when sync_strategy is longest, never for PDNG" do
    @enable_banking_item.update!(sync_strategy: "longest")
    @importer.stubs(:include_pending?).returns(true)

    # allow_longest_retry is false here (allow_longest_retry_for only applies
    # to the "date" strategy escalating on failure) - harmless, since
    # next_transactions_attempt's already_longest guard skips the insertion
    # rung anyway once the initial request is already strategy: "longest".
    @importer.expects(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entries(transaction_status: "BOOK", strategy: "longest", allow_longest_retry: false))
      .returns([])
    @importer.expects(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entries(transaction_status: "PDNG", strategy: nil, allow_longest_retry: false))
      .returns([])

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
  end

  test "fetch_and_store_transactions does not request strategy longest for an incremental sync" do
    @enable_banking_item.update!(sync_strategy: "longest")
    @enable_banking_item.stubs(:last_synced_at).returns(10.days.ago)
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "1" } ])
    @importer.stubs(:include_pending?).returns(false)

    # Once transactions are stored, the sync is incremental: the request must
    # use the bounded catch-up window and never strategy: "longest", which
    # would re-fetch the full available history on every routine sync.
    @importer.expects(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entries(
        transaction_status: "BOOK",
        start_date: 10.days.ago.to_date - 7.days,
        strategy: nil,
        allow_longest_retry: false
      ))
      .returns([])

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
  end

  test "fetch_and_store_transactions does not request strategy longest when sync_strategy is date" do
    @importer.stubs(:include_pending?).returns(false)

    @importer.expects(:fetch_paginated_transactions)
      .with(@enable_banking_account, has_entries(transaction_status: "BOOK", strategy: nil, allow_longest_retry: true))
      .returns([])

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
  end

  test "fetch_paginated_transactions repeats the provider's effective retry parameters on continuation pages" do
    original_date = 1.year.ago.to_date
    effective_date = 89.days.ago.to_date

    # Page 1 succeeds only after the provider retried internally with a
    # different date_from/strategy; the continuation request must repeat
    # those effective parameters, not the ones originally passed in.
    @mock_provider.expects(:get_account_transactions)
      .with(has_entries(date_from: original_date, strategy: nil, continuation_key: nil))
      .returns({
        transactions: [ { "transaction_id" => "1" } ],
        continuation_key: "page2",
        effective_date_from: effective_date,
        effective_strategy: "longest"
      })
    @mock_provider.expects(:get_account_transactions)
      .with(has_entries(date_from: effective_date, strategy: "longest", continuation_key: "page2"))
      .returns({
        transactions: [ { "transaction_id" => "2" } ],
        continuation_key: nil,
        effective_date_from: effective_date,
        effective_strategy: "longest"
      })

    result = @importer.send(
      :fetch_paginated_transactions,
      @enable_banking_account,
      start_date: original_date,
      transaction_status: "BOOK"
    )

    assert_equal 2, result.count
  end

  test "fetch_and_store_transactions logs and reports failure when every WRONG_TRANSACTIONS_PERIOD retry is exhausted" do
    @importer.stubs(:include_pending?).returns(false)

    exhausted_error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"WRONG_TRANSACTIONS_PERIOD\"}",
      :validation_error,
      response_data: { error: "WRONG_TRANSACTIONS_PERIOD" }
    )
    @importer.stubs(:fetch_paginated_transactions).raises(exhausted_error)

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    end

    assert_not result[:success]
    debug_log = DebugLogEntry.last
    assert_equal "provider_sync_error", debug_log.category
    assert_equal "error", debug_log.level
    assert_equal "validation_error", debug_log.metadata["error_type"]
  end

  test "fetch_and_store_transactions reports the effective_date_from the provider granted for an initial date-strategy sync" do
    @importer.stubs(:include_pending?).returns(false)
    granted_date = 89.days.ago.to_date

    @mock_provider.stubs(:get_account_transactions).returns({
      transactions: [],
      continuation_key: nil,
      effective_date_from: granted_date,
      effective_strategy: "longest"
    })

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
    assert_equal granted_date, result[:effective_date_from]
  end

  test "fetch_and_store_transactions omits effective_date_from for an incremental sync" do
    @enable_banking_item.stubs(:last_synced_at).returns(10.days.ago)
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "1" } ])
    @importer.stubs(:include_pending?).returns(false)
    granted_date = 89.days.ago.to_date

    @mock_provider.stubs(:get_account_transactions).returns({
      transactions: [],
      continuation_key: nil,
      effective_date_from: granted_date,
      effective_strategy: nil
    })

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
    assert_nil result[:effective_date_from]
  end

  test "fetch_and_store_transactions falls back to the earliest returned transaction date when a WRONG_TRANSACTIONS_PERIOD retry escalated to an unbounded longest fetch" do
    saved_account = @enable_banking_item.enable_banking_accounts.create!(uid: "saved_uid", name: "Acct", currency: "EUR")
    @importer.stubs(:include_pending?).returns(false)
    earliest_date = 60.days.ago.to_date

    # effective_date_from: nil mirrors Provider::EnableBanking's response when
    # next_transactions_attempt escalated all the way to strategy: "longest"
    # with no date bound (no corrected_date_from offered by the ASPSP) - the
    # provider itself has no boundary to report, but the escalation is proof
    # the originally requested date was rejected.
    @mock_provider.stubs(:get_account_transactions).returns({
      transactions: [
        { "transaction_id" => "1", "booking_date" => earliest_date.iso8601 },
        { "transaction_id" => "2", "booking_date" => (earliest_date + 5.days).iso8601 }
      ],
      continuation_key: nil,
      effective_date_from: nil,
      effective_strategy: "longest"
    })

    result = @importer.send(:fetch_and_store_transactions, saved_account)

    assert result[:success]
    assert_equal earliest_date, result[:effective_date_from]
  end

  test "fetch_and_store_transactions reports nil effective_date_from when an unbounded longest fetch returns no transactions at all" do
    saved_account = @enable_banking_item.enable_banking_accounts.create!(uid: "saved_uid", name: "Acct", currency: "EUR")
    @importer.stubs(:include_pending?).returns(false)

    @mock_provider.stubs(:get_account_transactions).returns({
      transactions: [],
      continuation_key: nil,
      effective_date_from: nil,
      effective_strategy: "longest"
    })

    result = @importer.send(:fetch_and_store_transactions, saved_account)

    assert result[:success]
    assert_nil result[:effective_date_from]
  end

  test "import persists effective_sync_start_date so a later shortfall check reflects what the bank actually granted" do
    linked_enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      uid: "linked_uid", name: "Linked", currency: "EUR"
    )
    depository = Depository.create!
    linked_account = Account.create!(
      family: @family, name: "Linked", balance: 0, cash_balance: 0, currency: "EUR", accountable: depository
    )
    AccountProvider.create!(account: linked_account, provider: linked_enable_banking_account)

    granted_date = 89.days.ago.to_date

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_update_balance).returns(true)
    @importer.stubs(:fetch_and_store_transactions).returns(
      success: true, transactions_count: 0, effective_date_from: granted_date
    )

    @importer.import

    assert_equal granted_date, @enable_banking_item.reload.effective_sync_start_date
  end

  test "import never moves effective_sync_start_date earlier - a later account's less-restrictive initial fetch must not erase an earlier account's shortfall" do
    linked_enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      uid: "linked_uid", name: "Linked", currency: "EUR"
    )
    depository = Depository.create!
    linked_account = Account.create!(
      family: @family, name: "Linked", balance: 0, cash_balance: 0, currency: "EUR", accountable: depository
    )
    AccountProvider.create!(account: linked_account, provider: linked_enable_banking_account)

    # A previous sync already recorded a restrictive boundary (e.g. from a
    # different account that has since become incremental and no longer
    # contributes to this sync's effective_date_froms). A later (more recent)
    # effective date is the more restrictive one - it means less history was
    # granted.
    restrictive_date = 30.days.ago.to_date
    @enable_banking_item.update_column(:effective_sync_start_date, restrictive_date)

    less_restrictive_date = 200.days.ago.to_date

    @enable_banking_item.stubs(:upsert_enable_banking_snapshot!)
    @importer.stubs(:fetch_session_data).returns(accounts: [])
    @importer.stubs(:fetch_and_update_balance).returns(true)
    @importer.stubs(:fetch_and_store_transactions).returns(
      success: true, transactions_count: 0, effective_date_from: less_restrictive_date
    )

    @importer.import

    assert_equal restrictive_date, @enable_banking_item.reload.effective_sync_start_date
  end
end
