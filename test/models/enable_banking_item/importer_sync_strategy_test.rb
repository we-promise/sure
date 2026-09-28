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
end
