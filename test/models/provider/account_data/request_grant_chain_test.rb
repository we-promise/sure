require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RequestGrantChainTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "only the complete ordered cookie rotation chain admits a generation" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      grant = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: sync)
      original = grant.snapshot
      captures = 2.times.map { |index| rotate(connection, grant, sync, "cookie-#{index}") }
      assert verify(connection, sync, original, captures)
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, original, captures.reverse) }
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, original, captures.drop(1)) }
      connection.update!(credentials: { "session_blob" => "unrecorded" })
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, original, captures) }
    end
  end

  test "same sync factory reconstruction may recapture only its clock while retaining all input fingerprints" do
    with_provider_encryption do
      connection = create_provider_connection
      sync = connection.syncs.create!
      first = captured_factory(connection, sync)
      original = first.snapshot
      captures = [ rotate(connection, first, sync, "cookie-first") ]
      travel 1.minute do
        second = captured_factory(connection, sync)
        captures << rotate(connection, second, sync, "cookie-second")
        assert verify(connection, sync, original, captures, runtime: true)
      end
      altered = Marshal.load(Marshal.dump(captures))
      altered.last["before"]["runtime_inputs"]["configuration"] = "f" * 64
      altered.last["after"]["runtime_inputs"]["configuration"] = "f" * 64
      assert_raises(Provider::AccountData::StaleWriter) { verify(connection, sync, original, altered, runtime: true) }
    end
  end

  test "ordinary direct-token generation verification remains strict after a recorded cookie rotation" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "plaid")
      sync = connection.syncs.create!
      grant = Provider::AccountData::RequestGrant.new(connection).capture!(scope_sync: sync)
      original = grant.snapshot
      rotate(connection, grant, sync, "cookie")
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::RequestGrant.verify_snapshot!(connection: connection, snapshot: original, scope_sync: sync)
      end
    end
  end

  private
    def captured_factory(connection, sync)
      grant = Provider::AccountData::RequestGrant.new(connection)
      grant.with_adapter_snapshot(adapter: Provider::AccountData::Up, observed_at: sync.created_at, sync: sync) { }
      grant
    end

    def rotate(connection, grant, sync, value)
      _response, capture = grant.capture_request(scope_sync: sync) do
        connection.with_lock do
          previous = connection.credential_revision
          connection.update!(credentials: { "session_blob" => value })
          grant.accept_credential_rotation!(from_revision: previous, kind: "session")
        end
        Provider::AccountData::Page.new(records: [], complete: false)
      end
      capture
    end

    def verify(connection, sync, original, captures, runtime: false)
      Provider::AccountData::RequestGrant.verify_chain!(connection: connection, initial_snapshot: original,
        captures: captures, require_runtime_inputs: runtime, scope_sync: sync)
    end
end
