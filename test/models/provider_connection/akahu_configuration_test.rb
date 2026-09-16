require "test_helper"
require_relative "../../support/akahu_native_management_test_helper"

class ProviderConnection::AkahuConfigurationTest < ActiveSupport::TestCase
  include AkahuNativeManagementTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Configuration = ProviderConnection::Configuration
  Adapter = Provider::AccountData::Akahu

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Adapter.stubs(:native_ready?).returns(true)
  end

  teardown { clear_enqueued_jobs }

  test "both native credentials change atomically without rewriting copied credentials or archives" do
    with_copied_unlinked_akahu do |connection, actor, _external, source, mapping|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      assert_equal %w[app_token user_token], form.credential_fields
      refute_includes form.token, "original-app-token"
      refute_includes form.token, "original-user-token"
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      original = [ source.akahu_item.reload.attributes, source.reload.attributes, mapping.reload.attributes,
        mapping.provider_migration_control.reload.attributes, akahu_archive_snapshot(connection) ]
      revision, epoch = connection.reload.attributes.values_at("credential_revision", "writer_epoch")
      Provider::Akahu.expects(:new).never

      assert_no_enqueued_jobs do
        command.update!(token: form.token, attributes: { "app_token" => "replacement-app", "user_token" => "replacement-user" })
      end

      assert_equal({ "app_token" => "replacement-app", "user_token" => "replacement-user" }, connection.reload.credentials)
      assert_equal [ revision + 1, epoch + 1 ], connection.attributes.values_at("credential_revision", "writer_epoch")
      assert_provider_column_encrypted(connection, :credentials, "replacement-app")
      assert_provider_column_encrypted(connection, :credentials, "replacement-user")
      assert_equal original, [ source.akahu_item.reload.attributes, source.reload.attributes, mapping.reload.attributes,
        mapping.provider_migration_control.reload.attributes, akahu_archive_snapshot(connection) ]
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
      before = connection.attributes
      assert_raises(Configuration::Conflict) { command.update!(token: form.token, attributes: { "user_token" => "stale" }) }
      assert_equal before, connection.reload.attributes
    end
  end

  test "blank fields preserve each credential independently and a fully blank update is a no-op" do
    with_akahu_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      token = command.form.token
      original = connection.reload.attributes
      Provider::Akahu.expects(:new).never

      command.update!(token: token, attributes: { "app_token" => "", "user_token" => "" })
      assert_equal original, connection.reload.attributes
      command.update!(token: token, attributes: { "app_token" => "new-app", "user_token" => "" })
      assert_equal({ "app_token" => "new-app", "user_token" => "original-user-token" }, connection.reload.credentials)
      command.update!(token: command.form.token, attributes: { "app_token" => "", "user_token" => "new-user" })
      assert_equal({ "app_token" => "new-app", "user_token" => "new-user" }, connection.reload.credentials)
      assert_equal 2, connection.credential_revision
      assert_empty connection.syncs
    end
  end

  test "declared management capabilities do not enable Akahu production readiness" do
    Adapter.unstub(:native_ready?)
    with_akahu_connection do |connection, actor|
      external = create_external_account(connection, currency: "NZD")
      refute Adapter.native_ready?
      Provider::Akahu.expects(:new).never

      assert_raises(Provider::AccountData::UnsupportedCapability) { Configuration.new(connection: connection, actor: actor).form }
      assert_raises(Provider::AccountData::UnsupportedCapability) do
        ProviderConnection::AccountSetup.new(connection: connection, actor: actor).form(external_account_id: external.id)
      end
      assert_empty connection.syncs
      assert_nil external.reload.current_account
    end
  end
end
