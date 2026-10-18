require "test_helper"

class DirectaItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @directa_item = create_directa_item(owner: @user)
  end

  teardown do
    Current.reset
  end

  test "sync queues a read for a connected owner-scoped item" do
    DirectaItem.any_instance.expects(:syncable?).returns(true)
    DirectaItem.any_instance.expects(:syncing?).returns(false)
    DirectaItem.any_instance.expects(:sync_later).once

    with_directa_access do
      post sync_directa_item_path(@directa_item)
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path(anchor: "directa")
    assert_equal I18n.t("directa_items.sync.queued"), flash[:notice]
  end

  test "sync rejects an item without a verified session" do
    DirectaItem.any_instance.expects(:syncable?).returns(false)
    DirectaItem.any_instance.expects(:sync_later).never

    with_directa_access do
      post sync_directa_item_path(@directa_item)
    end

    assert_response :see_other
    assert_equal I18n.t("directa_items.sync.unavailable"), flash[:alert]
  end

  test "an administrator cannot manage another owner's item" do
    other_admin = users(:empty)
    other_admin.update!(preferences: (other_admin.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other_admin

    with_directa_access do
      post sync_directa_item_path(@directa_item)
    end

    assert_response :not_found
  end

  test "disconnect invalidates the token while retaining the Directa account snapshot" do
    provider_account = DirectaAccount.create!(
      directa_item: @directa_item,
      currency: "EUR",
      current_balance: BigDecimal("100"),
      cash_balance: BigDecimal("25"),
      raw_position_metadata: []
    )

    with_directa_access do
      delete directa_item_path(@directa_item)
    end

    assert_response :see_other
    assert_equal I18n.t("directa_items.destroy.success"), flash[:notice]
    assert @directa_item.reload.requires_update?
    assert_nil @directa_item.multi_token
    assert_equal provider_account.id, @directa_item.directa_accounts.sole.id
    assert_equal BigDecimal("100"), provider_account.reload.current_balance
  end

  test "impersonated sessions cannot sync Directa" do
    impersonation = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @user,
      status: :in_progress
    )
    @user.sessions.order(:created_at).last.update!(active_impersonator_session: impersonation)

    with_directa_access do
      post sync_directa_item_path(@directa_item)
    end

    assert_response :forbidden
  end

  private

    def create_directa_item(owner:)
      DirectaItem.create!(
        family: owner.family,
        owner: owner,
        broker_account: "00123",
        account_identity: "verified-account-123",
        multi_token: "synthetic-multi-token",
        mono_token: "synthetic-mono-token",
        status: :connected,
        connection_generation: 1
      )
    end

    def with_directa_access
      with_self_hosting { yield }
    end
end
