require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RequestGrantTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "adapter construction pins the same connection credentials and authorization context" do
    with_connection do |connection|
      authorization = connection.provider_authorizations.create!(credentials: { "session_id" => "private-session" })
      factory = Class.new(Provider::AccountData::Up) do
        def self.context_sources
          [ :authorizations ]
        end
      end
      grant = Provider::AccountData::RequestGrant.new(connection)
      built = Provider::AccountData::Adapter.new(client: nil)
      Provider::AccountData::Registry.stubs(:fetch).with("up").returns(factory)
      factory.expects(:build).with do |arguments|
        arguments[:credentials] == connection.credentials && arguments[:settings] == connection.settings &&
          arguments[:context][:authorizations].sole[:credentials]["session_id"] == "private-session" &&
          grant.snapshot.fetch("authorizations").sole.fetch("lock_version") == authorization.lock_version
      end.returns(built)
      assert_same built, Provider::AccountData::Registry.build(connection, observed_at: Time.current, request_grant: grant)
      refute_includes JSON.generate(grant.snapshot), "private-session"
      refute_includes JSON.generate(grant.snapshot), "old-refresh-token"
    end
  end

  test "credential changes before HTTP cannot recapture a stale adapter's grant" do
    with_connection do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      connection.update!(credentials: { "refresh_token" => "another-owner-token" })
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk "Stale adapter cannot request data" } }
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture! }
    end
  end

  test "same timestamp authorization replacement and membership changes invalidate cached context" do
    with_connection do |connection|
      freeze_time do
        authorization = connection.provider_authorizations.create!(credentials: { "session_id" => "initial" })
        external = create_external_account(connection)
        membership = ProviderAuthorizationAccount.create!(provider_authorization: authorization, external_account: external)
        grant = Provider::AccountData::RequestGrant.new(connection).capture!
        authorization.update!(credentials: { "session_id" => "replacement" })
        assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
        newer = Provider::AccountData::RequestGrant.new(connection).capture!
        membership.update!(status: "revoked")
        membership.update!(status: "active")
        assert_raises(Provider::AccountData::StaleWriter) { newer.capture_request { flunk } }
      end
    end
  end

  test "expiration invalidates a grant without any database revision change" do
    with_connection do |connection|
      connection.provider_authorizations.create!(expires_at: 1.hour.from_now)
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      travel_to(2.hours.from_now) do
        assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk } }
      end
    end
  end

  test "a credential replacement during HTTP retains the original request identity and cannot publish" do
    with_connection do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      response, capture = grant.capture_request do
        connection.update!(credentials: { "refresh_token" => "replacement" })
        empty_page
      end
      page = Provider::AccountData::RequestGrant.attach(response, capture)
      assert_equal 0, page.evidence["request_grant"]["before"]["connection"]["credential_revision"]
      assert_equal 0, page.evidence["request_grant"]["after"]["connection"]["credential_revision"]
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: page.evidence["request_grant"])
      end
    end
  end

  test "only successful bound refresh and cookie writes advance the active request revision" do
    with_connection(provider_key: "questrade") do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection)
      store = nil
      Provider::AccountData::Registry.stubs(:fetch).with("questrade").returns(Provider::AccountData::Questrade)
      Provider::AccountData::Questrade.expects(:build).with do |arguments|
        store = arguments.fetch(:context).fetch(:credential_store)
        true
      end.returns(Provider::AccountData::Adapter.new(client: nil))
      Provider::AccountData::Registry.build(connection, observed_at: Time.current, request_grant: grant)
      response, capture = grant.capture_request do
        store.with_session_lock do |session|
          session.begin_refresh!
          session.persist_credentials!("refresh_token" => "next-refresh-token")
          session.persist_session_credentials!("cookies" => { "session" => "next-cookie" })
          session.persist_session_credentials!("cookies" => { "session" => "next-cookie" })
        end
        empty_page
      end
      assert response.complete?
      assert_equal [ "refresh", "session" ], capture["rotations"].map { |rotation| rotation["kind"] }
      assert_equal 0, capture["before"]["connection"]["credential_revision"]
      assert_equal 2, capture["after"]["connection"]["credential_revision"]
      assert_equal capture["before"]["runtime_inputs"], capture["after"]["runtime_inputs"]
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)
      refute_includes JSON.generate(capture), "next-cookie"
      refute_includes JSON.generate(capture), "next-refresh-token"
      grant.capture_request do
        store.with_session_lock { |session| assert_equal "next-cookie", session.credentials.dig("cookies", "session") }
      end
      assert_raises(Provider::AccountData::StaleWriter) { store.with_session_lock { flunk "Request capability expired" } }
    end
  end

  test "an independent credential store cannot authorize a stale request by rotating its token" do
    with_connection do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      _response, capture = grant.capture_request do
        Provider::AccountData::CredentialStore.new(connection: connection).with_session_lock do |session|
          session.persist_session_credentials!("cookies" => { "session" => "other-execution" })
        end
        empty_page
      end
      assert_empty capture["rotations"]
      assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture) }
    end
  end

  test "consent changes during refresh cannot be accepted as a credential rotation" do
    with_connection do |connection|
      authorization = connection.provider_authorizations.create!
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      store = Provider::AccountData::CredentialStore.new(connection: connection, request_grant: grant)
      grant.capture_request do
        store.with_session_lock do |session|
          session.begin_refresh!
          authorization.update!(status: "revoked")
          assert_raises(Provider::AccountData::StaleWriter) { session.persist_credentials!("refresh_token" => "must-not-persist") }
        end
      end
      assert_equal "old-refresh-token", connection.reload.credentials["refresh_token"]
      assert_equal "refreshing", connection.credential_state["status"]
    end
  end

  test "provider responses cannot inject grant evidence and malformed transitions cannot publish" do
    with_connection do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      _response, capture = grant.capture_request { empty_page }
      [ "request_grant", :request_grant, "request_inputs", :request_inputs ].each do |key|
        forged = Provider::AccountData::Page.new(records: [], complete: true, evidence: { key => {} })
        assert_raises(Provider::AccountData::InvalidResponse) { Provider::AccountData::RequestGrant.attach(forged, capture) }
        nested = Provider::AccountData::Page.new(records: [], complete: false, evidence: { key => {} })
        group = Provider::AccountData::TransactionGroup.new(generation_id: SecureRandom.uuid, start_cursor: nil,
          request_cursor: nil, next_cursor: "terminal", complete: true, account_pages: { "account" => nested }, unassigned_removed_ids: [], evidence: {})
        assert_raises(Provider::AccountData::InvalidResponse) { Provider::AccountData::RequestGrant.attach(group, capture) }
      end
      changed = capture.deep_dup
      changed["rotations"] = [ { "kind" => "session", "from_revision" => 0, "to_revision" => 2 } ]
      assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: changed) }
      assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: nil) }
    end
  end

  test "a grant cannot be supplied to another connection's credential store" do
    with_connection do |connection|
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      with_connection do |other|
        assert_raises(Provider::AccountData::StaleWriter) { Provider::AccountData::CredentialStore.new(connection: other, request_grant: grant) }
      end
    end
  end

  test "oversized authorization inventories fail before adapter construction" do
    with_connection do |connection|
      2.times { connection.provider_authorizations.create! }
      owner = Provider::AccountData::RequestGrant
      limit = owner::MAX_AUTHORIZATIONS
      owner.send(:remove_const, :MAX_AUTHORIZATIONS)
      owner.const_set(:MAX_AUTHORIZATIONS, 1)
      assert_raises(Provider::AccountData::IncompletePage) { owner.new(connection).with_adapter_snapshot { flunk } }
    ensure
      owner.send(:remove_const, :MAX_AUTHORIZATIONS)
      owner.const_set(:MAX_AUTHORIZATIONS, limit)
    end
  end

  private
    def with_connection(**attributes)
      with_provider_encryption do
        connection = create_provider_connection(credentials: { "refresh_token" => "old-refresh-token" }, **attributes)
        yield connection
      ensure
        connection&.reload&.destroy!
      end
    end

    def empty_page
      Provider::AccountData::Page.new(records: [], complete: true)
    end
end
