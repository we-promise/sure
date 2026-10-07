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

  test "fetch_paginated_transactions records a debug log when an initial longest fetch hits the page limit" do
    page = 0
    @mock_provider.define_singleton_method(:get_account_transactions) do |**_params|
      page += 1
      { transactions: [ { "transaction_id" => page.to_s } ], continuation_key: "page#{page + 1}" }
    end

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = @importer.send(
        :fetch_paginated_transactions,
        @enable_banking_account,
        start_date: nil,
        transaction_status: "BOOK",
        strategy: "longest"
      )
    end

    assert_equal EnableBankingItem::Importer::MAX_PAGINATION_PAGES, result.count
    debug_log = DebugLogEntry.last
    assert_equal "provider_sync_error", debug_log.category
    assert_equal "error", debug_log.level
    assert_equal "page_limit", debug_log.metadata["reason"]
    assert_equal "longest", debug_log.metadata["strategy"]
    assert_equal true, debug_log.metadata["history_gap"]
    assert_equal EnableBankingItem::Importer::MAX_PAGINATION_PAGES, debug_log.metadata["transactions_kept"]
  end

  test "fetch_paginated_transactions records a warning when an incremental fetch repeats its continuation key" do
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "0" } ])
    @mock_provider.stubs(:get_account_transactions)
      .returns({ transactions: [ { "transaction_id" => "1" } ], continuation_key: "stuck" })

    assert_difference "DebugLogEntry.count", 1 do
      @importer.send(
        :fetch_paginated_transactions,
        @enable_banking_account,
        start_date: 10.days.ago.to_date,
        transaction_status: "BOOK"
      )
    end

    debug_log = DebugLogEntry.last
    assert_equal "warn", debug_log.level
    assert_equal "repeated_continuation_key", debug_log.metadata["reason"]
    assert_equal false, debug_log.metadata["history_gap"]
  end

  test "fetch_and_store_transactions keeps the pages but reports failure when the initial fetch is truncated" do
    @enable_banking_item.update!(sync_strategy: "longest")
    @importer.stubs(:include_pending?).returns(false)
    page = 0
    @mock_provider.define_singleton_method(:get_account_transactions) do |**_params|
      page += 1
      { transactions: [ { "transaction_id" => page.to_s, "booking_date" => Date.current.iso8601 } ], continuation_key: "page#{page + 1}" }
    end
    @enable_banking_account.expects(:upsert_enable_banking_transactions_snapshot!)
      .with { |snapshot| snapshot.size == EnableBankingItem::Importer::MAX_PAGINATION_PAGES }

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert_not result[:success]
    assert_equal I18n.t("enable_banking_items.errors.history_truncated"), result[:error]
  end

  test "fetch_and_store_transactions still succeeds when an incremental fetch is truncated" do
    @importer.stubs(:include_pending?).returns(false)
    @enable_banking_account.stubs(:raw_transactions_payload).returns([ { "transaction_id" => "0" } ])
    @enable_banking_account.stubs(:upsert_enable_banking_transactions_snapshot!)
    @mock_provider.stubs(:get_account_transactions)
      .returns({ transactions: [ { "transaction_id" => "1", "booking_date" => Date.current.iso8601 } ], continuation_key: "stuck" })

    result = @importer.send(:fetch_and_store_transactions, @enable_banking_account)

    assert result[:success]
  end
end
