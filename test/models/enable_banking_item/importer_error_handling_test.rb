require "test_helper"
require "ostruct"

class EnableBankingItem::ImporterErrorHandlingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "AT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  # Session-level auth failures (the top-level GET /sessions call) mean the consent
  # is genuinely dead and the user must re-authorize.
  test "handle_sync_error with session_level flips requires_update on unauthorized" do
    error = Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    message = @importer.send(:handle_sync_error, error, session_level: true)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error with session_level flips requires_update on not_found" do
    error = Provider::EnableBanking::EnableBankingError.new("Not Found", :not_found)
    message = @importer.send(:handle_sync_error, error, session_level: true)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
  end

  # Per-account auth failures (a stale account UID, a transient hiccup on one
  # account) must NOT kill the whole connection — that is what made every sync
  # report "session expired". They surface as ordinary api errors and retry.
  test "handle_sync_error per-account unauthorized does not flip requires_update" do
    error = Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.api_error"), message
    assert_not @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error per-account not_found does not flip requires_update" do
    error = Provider::EnableBanking::EnableBankingError.new("Not Found", :not_found)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.api_error"), message
    assert_not @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error handles other EnableBankingError as api_error" do
    error = Provider::EnableBanking::EnableBankingError.new("Some API error", :internal_server_error)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.api_error"), message
    assert_not @enable_banking_item.reload.requires_update?
  end

  test "fetch_session_data updates status to requires_update on unauthorized error" do
    def @mock_provider.get_session(**args)
      raise Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    end

    @importer.send(:fetch_session_data)

    assert @enable_banking_item.reload.requires_update?
  end

  test "fetch_session_data reconciles session_expires_at from API access.valid_until" do
    new_expiry = 45.days.from_now.change(usec: 0)
    @mock_provider.stubs(:get_session).returns({ access: { valid_until: new_expiry.iso8601 } })

    @importer.send(:fetch_session_data)

    assert_equal new_expiry.to_i, @enable_banking_item.reload.session_expires_at.to_i
  end

  test "fetch_and_store_transactions does not flip whole connection on per-account unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.expects(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized))

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert_not result[:success]
    assert_not @enable_banking_item.reload.requires_update?
  end

  test "fetch_and_store_transactions succeeds and skips pending when ASPSP rejects PDNG transaction_status" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    pdng_error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: {\"message\":\"Wrong transactionStatus provided in getAccountTransactions call: PDNG\"}",
      :validation_error
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(pdng_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert result[:success]
  end

  # Regression for #392: Trade Republic (via Enable Banking) rejects the PDNG request
  # with a plain 400 (:bad_request) instead of the 422 (:validation_error) other ASPSPs use.
  test "fetch_and_store_transactions succeeds and skips pending when ASPSP rejects PDNG with a bad_request error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    trade_republic_pdng_error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"WRONG_REQUEST_PARAMETERS\"}",
      :bad_request,
      response_data: { error: "WRONG_REQUEST_PARAMETERS" }
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(trade_republic_pdng_error)

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = @importer.send(:fetch_and_store_transactions, enable_banking_account)
    end

    assert result[:success]
    debug_log = DebugLogEntry.last
    assert_equal "provider_sync_error", debug_log.category
    assert_equal "bad_request", debug_log.metadata["error_type"]
  end

  # Regression for #1805: ImaginV2 (and other Enable Banking connectors) reject PDNG with
  # a generic WRONG_REQUEST_PARAMETERS body whose message does not mention "transactionStatus".
  # The sync must still succeed and import booked transactions.
  test "fetch_and_store_transactions succeeds when ASPSP rejects PDNG with WRONG_REQUEST_PARAMETERS" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    imagin_error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: {\"error\":\"WRONG_REQUEST_PARAMETERS\"}",
      :validation_error,
      response_data: { error: "WRONG_REQUEST_PARAMETERS" }
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(imagin_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert result[:success]
  end

  test "fetch_and_store_transactions propagates non-validation EnableBankingError from PDNG fetch" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.stubs(:include_pending?).returns(true)

    rate_limit_error = Provider::EnableBanking::EnableBankingError.new(
      "Rate limit exceeded. Please try again later.",
      :rate_limited
    )

    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "BOOK")).returns([])
    @importer.stubs(:fetch_paginated_transactions).with(enable_banking_account, has_entries(transaction_status: "PDNG")).raises(rate_limit_error)

    result = @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert_not result[:success]
  end

  # Regression for #392: Trade Republic (via Enable Banking) issues a continuation_key
  # on page 1 that its own API then rejects on page 2 as mismatched with
  # transaction_status (422 WRONG_REQUEST_PARAMETERS). Failing outright would discard
  # the page already fetched, so once at least one page has succeeded, a validation
  # error mid-pagination must be treated as "pagination exhausted" and keep the partial
  # result instead of raising.
  test "fetch_paginated_transactions keeps partial results when a validation error interrupts a later page" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    page1_tx = { transaction_id: "tx1" }
    page1_response = { transactions: [ page1_tx ], continuation_key: "next-page-key" }
    error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: transactionStatus in request is not the same as in continuationKey",
      :validation_error
    )

    @mock_provider.expects(:get_account_transactions).twice.returns(page1_response).then.raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      result = @importer.send(
        :fetch_paginated_transactions,
        enable_banking_account,
        start_date: Date.today,
        transaction_status: "BOOK"
      )

      assert_equal [ page1_tx ], result
    end

    debug_log = DebugLogEntry.last
    assert_equal "provider_sync_error", debug_log.category
    assert_equal "error", debug_log.level
    assert_equal "enable_banking", debug_log.provider_key
    assert_equal 1, debug_log.metadata["pages_kept"]
    assert_equal 1, debug_log.metadata["transactions_kept"]
  end

  # Regression for we-promise/sure#2828 review feedback (jjmata): the PDNG-unsupported
  # rescue in fetch_and_store_transactions already tolerates both :validation_error and
  # :bad_request, but fetch_paginated_transactions is the shared method behind both the
  # BOOK and PDNG fetches — without this, a :bad_request mid-PDNG-pagination would raise
  # here, propagate past the PDNG-unsupported rescue's partial-keep logic, and discard
  # the already-fetched PDNG page 1 entirely instead of keeping it like the BOOK path
  # does. Trade Republic only 400s on PDNG page 1 today, so this is currently latent,
  # but the two error types must stay symmetric for ASPSPs that don't.
  test "fetch_paginated_transactions keeps partial results when a bad_request interrupts a later PDNG page" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    page1_tx = { transaction_id: "tx1" }
    page1_response = { transactions: [ page1_tx ], continuation_key: "next-page-key" }
    error = Provider::EnableBanking::EnableBankingError.new(
      "Bad request to Enable Banking API: {\"error\":\"WRONG_REQUEST_PARAMETERS\"}",
      :bad_request,
      response_data: { error: "WRONG_REQUEST_PARAMETERS" }
    )

    @mock_provider.expects(:get_account_transactions).twice.returns(page1_response).then.raises(error)

    result = @importer.send(
      :fetch_paginated_transactions,
      enable_banking_account,
      start_date: Date.today,
      transaction_status: "PDNG"
    )

    assert_equal [ page1_tx ], result
  end

  # A validation error on the very first page has no prior page to fall back on, so it
  # is a real failure (not ASPSP pagination quirk) and must still propagate.
  test "fetch_paginated_transactions propagates a validation error on the very first page" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    error = Provider::EnableBanking::EnableBankingError.new("Bad request parameters", :validation_error)

    @mock_provider.expects(:get_account_transactions).once.raises(error)

    assert_raises(Provider::EnableBanking::EnableBankingError) do
      @importer.send(
        :fetch_paginated_transactions,
        enable_banking_account,
        start_date: Date.today,
        transaction_status: "BOOK"
      )
    end
  end

  # WRONG_TRANSACTIONS_PERIOD means the date range itself is invalid, not that
  # pagination is exhausted (unlike the continuation-key mismatch above). It must
  # still propagate mid-pagination instead of being swallowed as a truncated-but-
  # successful result, otherwise the remaining pages are silently dropped.
  test "fetch_paginated_transactions propagates a WRONG_TRANSACTIONS_PERIOD validation error mid-pagination" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    page1_tx = { transaction_id: "tx1" }
    page1_response = { transactions: [ page1_tx ], continuation_key: "next-page-key" }
    error = Provider::EnableBanking::EnableBankingError.new(
      "Validation error from Enable Banking API: invalid transaction period",
      :validation_error,
      response_data: { error: "WRONG_TRANSACTIONS_PERIOD" }
    )

    @mock_provider.expects(:get_account_transactions).twice.returns(page1_response).then.raises(error)

    assert_raises(Provider::EnableBanking::EnableBankingError) do
      @importer.send(
        :fetch_paginated_transactions,
        enable_banking_account,
        start_date: Date.today,
        transaction_status: "BOOK"
      )
    end
  end

  # Non-validation errors (e.g. rate limiting, network failures) mid-pagination are
  # real failures regardless of how many pages already succeeded, and must propagate
  # so the sync is retried rather than silently importing a truncated result.
  test "fetch_paginated_transactions propagates a non-validation error mid-pagination" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    page1_tx = { transaction_id: "tx1" }
    page1_response = { transactions: [ page1_tx ], continuation_key: "next-page-key" }
    error = Provider::EnableBanking::EnableBankingError.new("Rate limit exceeded. Please try again later.", :rate_limited)

    @mock_provider.expects(:get_account_transactions).twice.returns(page1_response).then.raises(error)

    assert_raises(Provider::EnableBanking::EnableBankingError) do
      @importer.send(
        :fetch_paginated_transactions,
        enable_banking_account,
        start_date: Date.today,
        transaction_status: "BOOK"
      )
    end
  end

  test "fetch_and_update_balance does not flip whole connection on per-account unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    def @mock_provider.get_account_balances(**args)
      raise Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    end

    result = @importer.send(:fetch_and_update_balance, enable_banking_account)

    assert_not result
    assert_not @enable_banking_item.reload.requires_update?
  end
end
