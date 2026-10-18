require "test_helper"

class Provider::DirectaAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    @item = DirectaItem.create!(family: @family, owner: @admin)
    Current.session = @admin.sessions.create!
  end

  teardown do
    Current.reset
  end

  test "Directa supports only the native Investment account type" do
    enable_preview!
    with_self_hosting do
      configs = Provider::DirectaAdapter.connection_configs(family: @family)

      assert_equal [ "Investment" ], Provider::DirectaAdapter.supported_account_types
      assert_equal "_top", configs.sole[:frame].to_s
      assert_equal Rails.application.routes.url_helpers.directa_login_path,
                   configs.sole[:new_account_path].call("Investment", nil)
      assert Provider::Factory.registered?("DirectaAccount")
    end
  end

  test "Directa setup requires a self-hosted preview-enabled admin in the same family" do
    with_self_hosting do
      assert_empty Provider::DirectaAdapter.connection_configs(family: @family)

      enable_preview!
      Current.reset
      assert_empty Provider::DirectaAdapter.connection_configs(family: @family)

      wrong_family_admin = users(:inactive_trial_user)
      wrong_family_admin.update!(preferences: (wrong_family_admin.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = wrong_family_admin.sessions.create!
      assert_empty Provider::DirectaAdapter.connection_configs(family: @family)

      member = users(:family_member)
      member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = member.sessions.create!
      assert_empty Provider::DirectaAdapter.connection_configs(family: @family)
    end

    enable_preview!
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    assert_empty Provider::DirectaAdapter.connection_configs(family: @family)
  end

  test "adapter exposes the Directa item sync path and native provider identity" do
    provider_account = mock("Directa account")
    provider_account.stubs(:directa_item).returns(@item)
    account = mock("Investment account")
    adapter = Provider::DirectaAdapter.new(provider_account, account: account)

    assert_equal "directa", adapter.provider_name
    assert_equal @item, adapter.item
    assert_equal Rails.application.routes.url_helpers.sync_directa_item_path(@item), adapter.sync_path
  end

  private

    def enable_preview!
      @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
      Current.session = @admin.sessions.create!
    end
end
