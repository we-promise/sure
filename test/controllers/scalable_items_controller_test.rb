require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItemsControllerTest < ActionDispatch::IntegrationTest
  include ScalableTestHelper

  setup do
    @user = scalable_owner
    sign_in @user
    Current.reset
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @item = scalable_connected_item(owner: @user)
  end

  teardown { Current.reset }

  test "sync queues a read for an owner-scoped connection" do
    ScalableItem.any_instance.expects(:syncing?).returns(false)
    ScalableItem.any_instance.expects(:sync_later).once

    post sync_scalable_item_path(@item)

    assert_response :see_other
    assert_redirected_to settings_providers_path(anchor: "scalable")
    assert_equal I18n.t("scalable_items.sync.queued"), flash[:notice]
  end

  test "sync respects the provider cooldown" do
    @item.update!(next_sync_at: 15.minutes.from_now)
    ScalableItem.any_instance.expects(:sync_later).never

    post sync_scalable_item_path(@item)

    assert_response :see_other
    assert_redirected_to settings_providers_path(anchor: "scalable")
    assert_equal I18n.t("scalable_items.sync.cooldown"), flash[:notice]
  end

  test "generic provider sync schedules only this admin's Scalable connection" do
    other_owner = users(:family_member)
    other_item = ScalableItem.create!(
      family: @user.family,
      owner: other_owner,
      credentials: JSON.generate(scalable_credentials),
      person_identity: "synthetic-person",
      status: :connected,
      connection_generation: 1
    )
    ScalableItem.any_instance.expects(:syncing?).once.returns(false)
    ScalableItem.any_instance.expects(:sync_later).once

    post sync_provider_settings_providers_path(provider_key: "scalable")

    assert_response :redirect
    assert_redirected_to settings_providers_path
    assert other_item.reload.connected?
  end

  test "another owner cannot sync or disconnect this connection" do
    other = users(:empty)
    other.update!(preferences: (other.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other
    Current.reset

    post sync_scalable_item_path(@item)
    assert_response :not_found
    delete scalable_item_path(@item)
    assert_response :not_found
    assert @item.reload.credentials.present?
  end

  test "disconnect revokes credentials and preserves saved account data" do
    account = @item.scalable_accounts.create!(
      uid: "synthetic-account",
      name: "Scalable Broker",
      currency: "EUR",
      kind: "broker",
      current_balance: BigDecimal("100"),
      cash_balance: BigDecimal("50")
    )

    delete scalable_item_path(@item)

    assert_response :see_other
    assert_equal I18n.t("scalable_items.destroy.success"), flash[:notice]
    assert @item.reload.requires_update?
    assert_nil @item.credentials
    assert_equal account.id, @item.scalable_accounts.sole.id
    assert_equal BigDecimal("100"), account.reload.current_balance
  end

  test "impersonated sessions cannot sync or disconnect Scalable" do
    impersonation = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @user,
      status: :in_progress
    )
    @user.sessions.order(:created_at).last.update!(active_impersonator_session: impersonation)

    ScalableItem.any_instance.expects(:sync_later).never

    post sync_scalable_item_path(@item)
    assert_response :forbidden
    delete scalable_item_path(@item)
    assert_response :forbidden
    post sync_provider_settings_providers_path(provider_key: "scalable")
    assert_response :forbidden
  end
end
