require "test_helper"

class FinecoItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    @fineco_item = create_fineco_item(owner: @user)
  end

  teardown do
    Current.reset
  end

  test "sync queues only an owned ready item" do
    FinecoItem.any_instance.expects(:syncable?).returns(true)
    FinecoItem.any_instance.expects(:syncing?).returns(false)
    FinecoItem.any_instance.expects(:sync_later).once

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_response :see_other
    assert_redirected_to accounts_path
    assert_equal I18n.t("fineco_items.sync.queued"), flash[:notice]
  end

  test "sync rejects an item that is not ready" do
    FinecoItem.any_instance.expects(:syncable?).returns(false)
    FinecoItem.any_instance.expects(:sync_later).never

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_response :see_other
    assert_equal I18n.t("fineco_items.sync.unavailable"), flash[:alert]
  end

  test "sync does not enqueue another run while one is active" do
    FinecoItem.any_instance.expects(:syncable?).returns(true)
    FinecoItem.any_instance.expects(:syncing?).returns(true)
    FinecoItem.any_instance.expects(:sync_later).never

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_response :see_other
    assert_equal I18n.t("fineco_items.sync.already_running"), flash[:notice]
  end

  test "stopping sync clears the session but preserves the Fineco item" do
    with_fineco_access do
      delete fineco_item_path(@fineco_item)
    end

    assert_response :see_other
    assert_redirected_to accounts_path
    assert_equal I18n.t("fineco_items.destroy.success"), flash[:notice]
    assert FinecoItem.exists?(@fineco_item.id)
    @fineco_item.reload
    assert @fineco_item.requires_update?
    assert_nil @fineco_item.gsessionid
    assert_equal "fineco-test-account", @fineco_item.bank_account_number
  end

  test "another family admin cannot manage this owner-scoped item" do
    other_admin = users(:empty)
    other_admin.update!(preferences: (other_admin.preferences || {}).merge("preview_features_enabled" => true))
    sign_in other_admin

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_response :not_found
  end

  test "managed hosting cannot manage Fineco items" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    delete fineco_item_path(@fineco_item)

    assert_response :not_found
  end

  test "preview access is required to manage Fineco items" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_redirected_to root_path
  end

  test "non-admin users cannot manage Fineco items" do
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    sign_in member

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_redirected_to accounts_path
  end

  test "impersonated sessions cannot manage Fineco items" do
    impersonation = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @user,
      status: :in_progress
    )
    @user.sessions.order(:created_at).last.update!(active_impersonator_session: impersonation)

    with_fineco_access do
      delete fineco_item_path(@fineco_item)
    end

    assert_response :forbidden
  end

  test "sync requires a valid CSRF token" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    with_fineco_access do
      post sync_fineco_item_path(@fineco_item)
    end

    assert_response :unprocessable_content
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private

    def create_fineco_item(owner:)
      FinecoItem.create!(
        family: owner.family,
        owner: owner,
        gsessionid: "encrypted-test-session-cookie",
        account_index: "2",
        dossier_index: "4",
        captured_at: Time.current,
        bank_account_number: "fineco-test-account",
        dossier_identity: Digest::SHA256.hexdigest("fineco-test-dossier"),
        status: "good"
      )
    end

    def with_fineco_access
      with_self_hosting { yield }
    end
end
