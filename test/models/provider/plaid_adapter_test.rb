require "test_helper"

class Provider::PlaidAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @plaid_account = plaid_accounts(:one)
    @account = accounts(:depository)
    @adapter = Provider::PlaidAdapter.new(@plaid_account, account: @account)
  end

  def adapter
    @adapter
  end

  # Run shared interface tests
  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  # Provider-specific tests
  test "returns correct provider name" do
    assert_equal "plaid", @adapter.provider_name
  end

  test "returns correct provider type" do
    assert_equal "PlaidAccount", @adapter.provider_type
  end

  test "returns plaid item" do
    assert_equal @plaid_account.plaid_item, @adapter.item
  end

  test "returns account" do
    assert_equal @account, @adapter.account
  end

  test "can_delete_holdings? returns false" do
    assert_equal false, @adapter.can_delete_holdings?
  end

  test "wrong settings key disables each Plaid region without weakening direct reads" do
    original_us = Rails.application.config.plaid
    original_eu = Rails.application.config.plaid_eu
    %w[plaid plaid_eu].each do |key|
      Setting["#{key}_client_id"] = "synthetic-client"
      Setting["#{key}_secret"] = "synthetic-secret"
    end
    Setting.stubs(:setting_encryptor).returns(ActiveSupport::MessageEncryptor.new("x" * 32))

    with_env_overrides("PLAID_SECRET" => "synthetic-env", "PLAID_EU_SECRET" => "synthetic-env") do
      Provider::PlaidAdapter.reload_configuration
      Provider::PlaidEuAdapter.reload_configuration

      assert_nil Rails.application.config.plaid
      assert_nil Rails.application.config.plaid_eu
      assert_nil Provider::Registry.plaid_provider_for_region(:us)
      assert_nil Provider::Registry.plaid_provider_for_region(:eu)
      assert_raises(Setting::SecretError) { Provider::PlaidAdapter.config_value(:secret) }
      assert_raises(Setting::SecretError) { Provider::PlaidEuAdapter.config_value(:secret) }
    end
  ensure
    Rails.application.config.plaid = original_us
    Rails.application.config.plaid_eu = original_eu
  end
end
