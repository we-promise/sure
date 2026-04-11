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

  test "handle_sync_error handles unauthorized EnableBankingError" do
    error = Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
  end

  test "handle_sync_error handles not_found EnableBankingError" do
    error = Provider::EnableBanking::EnableBankingError.new("Not Found", :not_found)
    message = @importer.send(:handle_sync_error, error)

    assert_equal I18n.t("enable_banking_items.errors.session_invalid"), message
    assert @enable_banking_item.reload.requires_update?
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

  test "fetch_and_store_transactions updates status to requires_update on unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    @importer.stubs(:determine_sync_start_date).returns(Date.today)
    @importer.expects(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized))

    @importer.send(:fetch_and_store_transactions, enable_banking_account)

    assert @enable_banking_item.reload.requires_update?
  end

  test "fetch_and_update_balance updates status to requires_update on unauthorized error" do
    enable_banking_account = EnableBankingAccount.new(uid: "test_uid")
    def @mock_provider.get_account_balances(**args)
      raise Provider::EnableBanking::EnableBankingError.new("Unauthorized", :unauthorized)
    end

    @importer.send(:fetch_and_update_balance, enable_banking_account)

    assert @enable_banking_item.reload.requires_update?
  end
end
