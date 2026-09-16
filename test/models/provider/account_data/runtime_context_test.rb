require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RuntimeContextTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "undeclared domain snapshots are not queried" do
    with_provider_encryption do
      connection = create_provider_connection
      connection.expects(:provider_authorizations).never
      connection.expects(:external_accounts).never
      connection.family.expects(:known_merchant_names).never
      context = Provider::AccountData::RuntimeContext.build(connection, adapter: Provider::AccountData::Mercury, observed_at: Time.current)
      assert_equal connection.family.timezone, context[:timezone]
      assert_equal connection.family.locale, context[:family_locale]
      refute context.key?(:authorizations)
    end
  end

  test "unknown context sources fail before resolving arbitrary methods" do
    with_provider_encryption do
      adapter = Class.new(Provider::AccountData::Mercury) do
        def self.context_sources
          [ :destroy! ]
        end
      end
      assert_raises(ArgumentError) do
        Provider::AccountData::RuntimeContext.build(create_provider_connection, adapter: adapter, observed_at: Time.current)
      end
    end
  end

  test "snapshots include decrypted grant credentials and only this connection memberships" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "enable_banking")
      authorization = connection.provider_authorizations.create!(family: connection.family,
        credentials: { "session_id" => "secret-session", "last_psu_ip" => "192.0.2.3" }, expires_at: 1.day.from_now)
      external = create_external_account(connection, sensitive_details: { "api_account_id" => "session-account" })
      ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
      other = create_provider_connection(family: families(:empty), provider_key: "enable_banking")
      other.provider_authorizations.create!(family: other.family, credentials: { "session_id" => "other-family-secret" })
      context = Provider::AccountData::RuntimeContext.build(connection, adapter: Provider::AccountData::EnableBanking, observed_at: Time.current)
      assert_equal [ authorization.id ], context[:authorizations].map { |grant| grant[:id] }
      assert_equal "secret-session", context[:authorizations].first[:credentials]["session_id"]
      assert_equal [ authorization.id ], context[:external_accounts].first[:authorization_ids]
      assert_equal "session-account", context[:external_accounts].first[:sensitive_details]["api_account_id"]
      context[:authorizations].first[:credentials]["session_id"].replace("changed")
      assert_equal "secret-session", authorization.reload.credentials["session_id"]
    end
  end

  test "trusted feature collectors receive the explicit connection and clock once" do
    with_provider_encryption do
      connection = create_provider_connection
      observed_at = Time.utc(2026, 9, 14)
      adapter = Class.new(Provider::AccountData::Mercury) do
        def self.context_sources
          [ :simplefin_balance_classification ]
        end
      end
      policy = { "enabled" => false, "settings" => {} }
      Ingestion::BalancePolicies::Simplefin::Snapshot.expects(:configuration).once.returns(policy)
      Ingestion::BalancePolicies::Simplefin::Snapshot.expects(:build).once
        .with(connection: connection, observed_at: observed_at, external_accounts: nil, configuration: policy, key_by: :id)
        .returns("account-uuid" => { "enabled" => false })
      context = Provider::AccountData::RuntimeContext.build(connection, adapter: adapter, observed_at: observed_at)
      assert_equal 2, context[:simplefin_balance_classification][:version]
      assert_equal false, context[:simplefin_balance_classification][:accounts]["account-uuid"]["enabled"]
    end
  end

  test "connection snapshots retain the explicitly selected history start date" do
    with_provider_encryption do
      connection = create_provider_connection(sync_start_date: Date.new(2020, 1, 15))
      details = Provider::AccountData::RuntimeContext.new(connection).connection_details
      assert_equal "2020-01-15", details[:sync_start_date]
    end
  end

  test "fresh pending preference preserves declared defaults and an explicit false value" do
    Setting.unscoped.where(var: "syncs_include_pending").delete_all
    Setting.clear_cache
    assert_equal Setting.syncs_include_pending, Provider::AccountData::RuntimeContext.pending_preference
    Setting.syncs_include_pending = false
    assert_equal false, Provider::AccountData::RuntimeContext.pending_preference
    Setting.syncs_include_pending = true
    assert_equal true, Provider::AccountData::RuntimeContext.pending_preference
  end
end
