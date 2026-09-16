require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::CredentialStoreTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "intent and rotated credentials are durable across sessions and encrypted" do
    with_store do |connection, store|
      store.with_session_lock do |session|
        session.begin_refresh!
        assert_equal "refreshing", connection.reload.credential_state.fetch("status")
        assert_equal "old-refresh-token", session.credentials.fetch("refresh_token")
        session.persist_credentials!("refresh_token" => "rotated-refresh-token", "access_token" => "new-access-token")
      end
      assert_equal 1, connection.reload.credential_revision
      assert_empty connection.credential_state
      assert_provider_column_encrypted(connection, :credentials, "rotated-refresh-token")
      store.with_session_lock do |session|
        assert_equal "rotated-refresh-token", session.credentials.fetch("refresh_token")
        assert_not session.refresh_pending?
      end
    end
  end

  test "a crash after refresh intent prevents reuse of the old token" do
    with_store do |connection, store|
      assert_raises(IOError) do
        store.with_session_lock do |session|
          session.begin_refresh!
          raise IOError, "simulated interrupted exchange"
        end
      end
      store.with_session_lock do |session|
        assert session.refresh_pending?
        assert_raises(Provider::AccountData::CredentialStore::ReauthorizationRequired) { session.begin_refresh! }
      end
      assert_equal "old-refresh-token", connection.reload.credentials.fetch("refresh_token")
      assert_equal 0, connection.credential_revision
      assert connection.requires_update?
    end
  end

  test "ambiguous exchange records reauthorization state and cannot be persisted by a later session" do
    with_store do |connection, store|
      store.with_session_lock do |session|
        session.begin_refresh!
        session.mark_refresh_uncertain!
      end
      assert connection.reload.requires_update?
      assert_equal "uncertain", connection.credential_state.fetch("status")
      store.with_session_lock do |session|
        assert_raises(Provider::AccountData::StaleWriter) do
          session.persist_credentials!("refresh_token" => "unowned-token")
        end
      end
      assert_equal "old-refresh-token", connection.reload.credentials.fetch("refresh_token")
    end
  end

  test "an enclosing transaction cannot roll back a committed refresh intent" do
    with_store do |connection, store|
      assert_raises(ArgumentError) do
        ProviderConnection.transaction { store.with_session_lock { flunk "must reject before exchange" } }
      end
      store.with_session_lock do |session|
        assert_raises(ArgumentError) do
          ProviderConnection.transaction { session.begin_refresh! }
        end
      end
      assert_empty connection.reload.credential_state
    end
  end

  test "closed sessions and changed credential revisions reject stale writes" do
    with_store do |connection, store|
      retained = nil
      store.with_session_lock do |session|
        retained = session
        session.begin_refresh!
        connection.reload.update!(credentials: { "refresh_token" => "reauthorized-token" }, credential_state: {}, credential_revision: 1)
        assert_raises(Provider::AccountData::StaleWriter) { session.persist_credentials!("refresh_token" => "stale-token") }
      end
      assert_raises(Provider::AccountData::StaleWriter) { retained.credentials }
      assert_equal "reauthorized-token", connection.reload.credentials.fetch("refresh_token")
    end
  end

  test "a disabled connection cannot hand out a still-valid access token" do
    with_store do |connection, store|
      connection.update!(status: "disabled")
      assert_raises(Provider::AccountData::StaleWriter) do
        store.with_session_lock { |session| session.credentials }
      end
    end
  end

  test "a competing database session cannot exchange the same token concurrently" do
    with_store do |connection, store|
      store.with_session_lock do |session|
        session.begin_refresh!
        outcome = Thread.new do
          begin
            Provider::AccountData::CredentialStore.new(connection: connection).with_session_lock { :unexpected_access }
          rescue Provider::AccountData::CredentialStore::Busy
            :busy
          end
        end.value
        assert_equal :busy, outcome
        session.persist_credentials!("refresh_token" => "one-rotated-token")
      end
      assert_equal "one-rotated-token", connection.reload.credentials.fetch("refresh_token")
    end
  end

  test "ordinary cookie updates commit without manufacturing single-use token intent" do
    with_store do |connection, store|
      store.with_session_lock do |session|
        session.persist_session_credentials!("cookies" => { "session" => "confirmed-cookie" })
        assert_not session.refresh_pending?
        assert_equal "confirmed-cookie", connection.reload.credentials.dig("cookies", "session")
        session.persist_session_credentials!("cookies" => { "session" => "confirmed-cookie" })
      end
      assert_equal 1, connection.reload.credential_revision
      assert connection.good?
      assert_empty connection.credential_state
      assert_raises(IOError) { store.with_session_lock { raise IOError, "failed ordinary read" } }
      assert connection.reload.good?
      assert_empty connection.credential_state
    end
  end

  test "ordinary cookie persistence cannot bypass an outstanding single-use exchange" do
    with_store do |connection, store|
      store.with_session_lock do |session|
        session.begin_refresh!
        assert_raises(Provider::AccountData::CredentialStore::ReauthorizationRequired) do
          session.persist_session_credentials!("cookies" => { "session" => "unrelated-cookie" })
        end
        session.persist_credentials!("refresh_token" => "confirmed-rotation")
      end
      assert_equal "confirmed-rotation", connection.reload.credentials.fetch("refresh_token")
      assert_empty connection.credential_state
    end
  end

  test "retired ownership permits refresh and a later pause invalidates the open session" do
    with_store do |connection, store|
      control = ProviderMigrationControl.create!(family: connection.family, provider_connection: connection,
        provider_key: "up", legacy_type: "UpItem", legacy_id: SecureRandom.uuid, state: "retired")
      store.with_session_lock do |session|
        session.begin_refresh!
        session.persist_credentials!("refresh_token" => "retired-owner-token")
        assert_equal "retired-owner-token", session.credentials.fetch("refresh_token")
        control.update!(state: "rollback_pending")
        assert_raises(Provider::AccountData::StaleWriter) { session.credentials }
        assert_raises(Provider::AccountData::StaleWriter) { session.begin_refresh! }
      end
      assert_equal "retired-owner-token", connection.reload.credentials.fetch("refresh_token")
      assert_empty connection.credential_state
    end
  end

  private
    def with_store
      with_provider_encryption do
        connection = create_provider_connection(credentials: { "refresh_token" => "old-refresh-token" })
        begin
          yield connection, Provider::AccountData::CredentialStore.new(connection: connection)
        ensure
          connection.provider_migration_control&.destroy!
          connection.reload.destroy!
        end
      end
    end
end
