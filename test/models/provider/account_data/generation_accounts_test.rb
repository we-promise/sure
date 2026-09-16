require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::GenerationAccountsTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "captured authorizations expire even when no persisted status or revision changes" do
    with_provider_encryption do
      connection, external = linked_account
      authorization = connection.provider_authorizations.create!(expires_at: 1.hour.from_now)
      ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
      snapshot = capture(connection).fetch(external.external_id)
      travel_to(2.hours.from_now) do
        assert_raises(Provider::AccountData::StaleWriter) { verify(connection, external, snapshot) }
      end
    end
  end

  test "same-timestamp grant credential changes invalidate the captured authorization revision" do
    with_provider_encryption do
      freeze_time do
        connection, external = linked_account
        authorization = connection.provider_authorizations.create!(credentials: { "session_id" => "first-session" })
        ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
        snapshot = capture(connection).fetch(external.external_id)
        authorization.update!(credentials: { "session_id" => "replacement-session" })
        assert_equal snapshot.fetch("authorizations").sole.fetch("updated_at"), authorization.updated_at.utc.iso8601(6)
        assert_raises(Provider::AccountData::StaleWriter) { verify(connection, external, snapshot) }
      end
    end
  end

  test "revoking and reactivating a membership does not restore an old capture's authority" do
    with_provider_encryption do
      freeze_time do
        connection, external = linked_account
        authorization = connection.provider_authorizations.create!
        membership = ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
        snapshot = capture(connection).fetch(external.external_id)
        membership.update!(status: "revoked")
        membership.update!(status: "active")
        assert_raises(Provider::AccountData::StaleWriter) { verify(connection, external, snapshot) }
      end
    end
  end

  test "linking a previously unlinked account cannot change the captured publication mode" do
    with_provider_encryption do
      connection = create_provider_connection
      external = create_external_account(connection)
      snapshot = capture(connection).fetch(external.external_id)
      assert_equal "retained", snapshot.fetch("publication")
      link = AccountProvider.create!(account: accounts(:depository), external_account: external)
      Account::SourcePolicy.select!(account: link.account, account_provider: link, resource: "transactions")
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, external, snapshot) }
    end
  end

  test "a binding from another connection cannot be presented as this connection's source" do
    with_provider_encryption do
      connection, external = linked_account
      snapshot = capture(connection).fetch(external.external_id)
      foreign_connection = create_provider_connection(family: families(:empty))
      foreign = create_external_account(foreign_connection, external_id: external.external_id)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, foreign, snapshot) }
    end
  end

  private
    def linked_account
      connection = create_provider_connection
      external = create_external_account(connection)
      link = AccountProvider.create!(account: accounts(:depository), external_account: external)
      Account::SourcePolicy.select!(account: link.account, account_provider: link, resource: "transactions")
      [ connection, external ]
    end

    def capture(connection)
      connection.with_lock { Provider::AccountData::GenerationAccounts.new(connection).capture }
    end

    def verify(connection, external, snapshot)
      connection.with_lock do
        Provider::AccountData::GenerationAccounts.new(connection).with_verified_binding(external, snapshot) { flunk "Stale binding must not be applied" }
      end
    end
end
