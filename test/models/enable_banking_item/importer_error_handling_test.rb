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

  test "fetch_paginated_transactions retries BOOK fetch on ASPSP_ERROR and returns later success" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid", account_id: SecureRandom.uuid)
    @importer.stubs(:sleep)

    error = Provider::EnableBanking::EnableBankingError.new(
      "Failed to fetch data: 500 - {\"error\":\"ASPSP_ERROR\"}",
      :aspsp_error,
      response_data: { error: "ASPSP_ERROR" }
    )

    @mock_provider.expects(:get_account_transactions).twice.raises(error).then.returns({ transactions: [], continuation_key: nil })

    result = @importer.send(
      :fetch_paginated_transactions,
      enable_banking_account,
      start_date: Date.today,
      transaction_status: "BOOK"
    )

    assert_equal [], result
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
