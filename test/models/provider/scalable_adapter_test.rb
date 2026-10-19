require "test_helper"

class Provider::ScalableAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @item = ScalableItem.create!(family: @family, owner: @admin)
    Current.session = @admin.sessions.create!
  end

  teardown { Current.reset }

  test "Scalable supports an Investment account with brokerage cash" do
    enable_preview!
    with_self_hosting do
      configs = Provider::ScalableAdapter.connection_configs(family: @family)

      assert_equal [ "Investment" ], Provider::ScalableAdapter.supported_account_types
      assert_equal "_top", configs.sole[:frame].to_s
      assert_equal Rails.application.routes.url_helpers.scalable_login_path,
                   configs.sole[:new_account_path].call("Investment", nil)
      assert Provider::Factory.registered?("ScalableAccount")
    end
  end

  test "connection setup requires a self-hosted preview-enabled admin in the same family" do
    with_self_hosting do
      assert_empty Provider::ScalableAdapter.connection_configs(family: @family)

      enable_preview!
      Current.reset
      assert_empty Provider::ScalableAdapter.connection_configs(family: @family)

      other_admin = users(:inactive_trial_user)
      other_admin.update!(preferences: (other_admin.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = other_admin.sessions.create!
      assert_empty Provider::ScalableAdapter.connection_configs(family: @family)

      member = users(:family_member)
      member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = member.sessions.create!
      assert_empty Provider::ScalableAdapter.connection_configs(family: @family)
    end

    enable_preview!
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    assert_empty Provider::ScalableAdapter.connection_configs(family: @family)
  end

  test "connection setup is unavailable in an impersonated session" do
    enable_preview!
    impersonation = ImpersonationSession.create!(
      impersonator: users(:sure_support_staff),
      impersonated: @admin,
      status: :in_progress
    )
    Current.session.update!(active_impersonator_session: impersonation)

    with_self_hosting do
      assert_empty Provider::ScalableAdapter.connection_configs(family: @family)
    end
  end

  test "adapter exposes the Scalable item and synchronization route" do
    provider_account = mock("Scalable account")
    provider_account.stubs(:scalable_item).returns(@item)
    provider_account.stubs(:account).returns(nil)
    adapter = Provider::ScalableAdapter.new(provider_account)

    assert_equal "scalable", adapter.provider_name
    assert_equal @item, adapter.item
    assert_equal Rails.application.routes.url_helpers.sync_scalable_item_path(@item), adapter.sync_path
    assert_equal "scalable.capital", adapter.institution_domain
  end

  private

    def enable_preview!
      @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = @admin.sessions.create!
    end
end
