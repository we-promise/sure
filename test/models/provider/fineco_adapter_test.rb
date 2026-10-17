require "test_helper"

class Provider::FinecoAdapterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    Current.session = @admin.sessions.create!
  end

  teardown do
    Current.reset
  end

  test "Fineco is available only for Investment accounts" do
    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))

    with_self_hosting do
      investment_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: "Investment",
        family: @family
      )
      bank_configs = Provider::Factory.connection_configs_for_account_type(
        account_type: "Depository",
        family: @family
      )

      fineco_config = investment_configs.find { |config| config[:key] == "fineco" }

      assert fineco_config
      assert_equal [ "Investment" ], Provider::FinecoAdapter.supported_account_types
      assert_equal Rails.application.routes.url_helpers.fineco_login_path,
                   fineco_config[:new_account_path].call("Investment", nil)
      assert_empty bank_configs.select { |config| config[:key] == "fineco" }
    end
  end

  test "Fineco account setup requires a self-hosted preview-enabled admin in the family" do
    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => false))

    with_self_hosting do
      assert_empty fineco_configs
    end

    @admin.update!(preferences: (@admin.preferences || {}).merge("preview_features_enabled" => true))
    member = users(:family_member)
    member.update!(preferences: (member.preferences || {}).merge("preview_features_enabled" => true))
    Current.session = member.sessions.create!

    with_self_hosting do
      assert_empty fineco_configs
    end

    Current.session = @admin.sessions.create!
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    assert_empty fineco_configs
  end

  private

    def fineco_configs
      Provider::FinecoAdapter.connection_configs(family: @family)
    end
end
