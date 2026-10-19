require "test_helper"
require Rails.root.join("test/support/ca_auto_bank_test_helper")

class CaAutoBankItemsControllerTest < ActionDispatch::IntegrationTest
  include CaAutoBankTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later)
    @item = ca_connected_item
    CaAutoBankItem::Importer.new(@item).import(snapshot: ca_snapshot(@item))
    sign_in @user
    Current.reset
  end

  teardown { Current.reset }

  test "accounts show native savings and CD accounts and contract details without bank credentials" do
    get accounts_path
    assert_response :success
    assert_includes response.body, "CA Auto Bank Libero"
    assert_includes response.body, "CA Auto Bank Tempo"
    refute_includes response.body, @item.authentication_token
    deposit = @item.ca_auto_bank_accounts.find_by!(kind: "time_deposit")
    get account_path(deposit.account)
    assert_response :success
    assert_select "section[aria-label=?]", I18n.t("ca_auto_bank.deposit_details")
    assert_includes response.body, I18n.t("ca_auto_bank.principal_note")
    assert_includes response.body, "3.50%"
    refute_includes response.body, "private-deposit"
  end

  test "expired connections request login while keeping all saved balances" do
    @item.update!(session_expires_at: 1.minute.ago)
    CaAutoBankItem.any_instance.expects(:sync_later).never
    post sync_ca_auto_bank_item_path(@item)
    assert_redirected_to ca_auto_bank_login_path
    assert_equal BigDecimal("3125"), @item.accounts.sum(:balance)
    get settings_providers_path
    assert_includes response.body, I18n.t("ca_auto_bank.errors.session_expired")
  end

  test "sync queues a ready item" do
    CaAutoBankItem.any_instance.expects(:sync_later).once.returns(:queued)

    post sync_ca_auto_bank_item_path(@item)

    assert_redirected_to settings_providers_path(anchor: "ca-auto-bank")
    assert_equal I18n.t("ca_auto_bank.sync_queued"), flash[:notice]
  end

  test "sync shows its persisted cooldown without enqueueing another snapshot" do
    @item.record_rate_limit!(retry_after: "3600", updates: { last_sync_error_code: "rate_limited" })
    CaAutoBankItem.any_instance.expects(:sync_later).never

    post sync_ca_auto_bank_item_path(@item)

    assert_redirected_to settings_providers_path(anchor: "ca-auto-bank")
    assert_equal @item.sync_cooldown_message, flash[:notice]
  end

  test "another owner cannot sync or disconnect this connection" do
    other = users(:empty)
    other.update!(preferences: (other.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other
    post sync_ca_auto_bank_item_path(@item)
    assert_response :not_found
    delete ca_auto_bank_item_path(@item)
    assert_response :not_found
    assert @item.reload.authentication_token.present?
  end

  test "generic provider sync cannot bypass the owner-only CA routes" do
    CaAutoBankItem.any_instance.expects(:sync_later).never
    post sync_provider_settings_providers_path(provider_key: "ca_auto_bank")
    assert_redirected_to settings_providers_path
  end

  test "an impersonated owner cannot dispatch a generic account sync or use the dedicated routes" do
    sign_in support = users(:sure_support_staff)
    impersonation = ImpersonationSession.create!(impersonator: support, impersonated: @user, status: :in_progress)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonation.id }
    CaAutoBankItem.any_instance.expects(:sync_later).never
    post sync_account_path(@item.accounts.first)
    assert_response :redirect
    get ca_auto_bank_login_path
    assert_response :forbidden
    post sync_ca_auto_bank_item_path(@item)
    assert_response :forbidden
  end
end
