require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class ProviderConnection::ConfigurationTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Configuration = ProviderConnection::Configuration
  Store = Provider::AccountData::CredentialStore

  test "native static replacement commits encrypted credentials and invalidates the original form and grant" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      original_id = connection.id
      assert_equal [ "access_token" ], form.credential_fields
      refute_includes form.token, "original-token"

      result = command.update!(token: form.token, attributes: { "name" => "Renamed", "access_token" => "replacement-token", "sync_start_date" => "2020-01-02" })

      assert_equal original_id, result.id
      assert_equal [ "Renamed", Date.new(2020, 1, 2), 1, 1 ], result.attributes.values_at("name", "sync_start_date", "credential_revision", "writer_epoch")
      assert_provider_column_encrypted(result, :credentials, "replacement-token")
      assert_equal "replacement-token", connection.reload.credentials.fetch("access_token")
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
      before = connection.attributes
      assert_raises(Configuration::Conflict) { command.update!(token: form.token, attributes: { "access_token" => "obsolete-token" }) }
      assert_equal before, connection.reload.attributes
      assert_empty connection.syncs
    end
  end

  test "blank credentials preserve the token and a no-op preserves its form and revisions" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      command.update!(token: form.token, attributes: { "access_token" => "", "name" => connection.name })
      assert_equal before, connection.reload.attributes
      command.update!(token: form.token, attributes: { "name" => "Changed name" })
      assert_equal 0, connection.reload.credential_revision
      assert_equal "original-token", connection.credentials.fetch("access_token")
      assert_equal 1, connection.writer_epoch
    end
  end

  test "an issued form cannot move between connections actors or families" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      second = create_provider_connection(family: actor.family, name: "Second")
      second_actor = actor.family.users.create!(email: "second-#{SecureRandom.uuid}@example.com", password: "configuration-password", role: "admin")
      foreign = users(:family_admin)
      [ [ second, actor ], [ connection, second_actor ], [ connection, foreign ] ].each do |target, user|
        before = target.reload.attributes
        assert_raises(Configuration::Conflict) do
          Configuration.new(connection: target, actor: user).update!(token: form.token, attributes: { "name" => "Wrong target" })
        end
        assert_equal before, target.reload.attributes
      end
    end
  end

  test "current administrator status is checked again when a form is submitted" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      actor.update!(role: "member")
      before = connection.reload.attributes
      assert_raises(Configuration::Conflict) { command.update!(token: form.token, attributes: { "access_token" => "denied-token" }) }
      assert_equal before, connection.reload.attributes
      assert_raises(Configuration::Conflict) { command.form }
    end
  end

  test "expired altered and oversized forms cannot write" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      [ "invalid", form.token + "x", "x" * (Configuration::MAX_TOKEN_BYTES + 1) ].each do |token|
        assert_raises(Configuration::Conflict) { command.update!(token: token, attributes: { "name" => "Denied" }) }
      end
      travel 31.minutes do
        assert_raises(Configuration::Conflict) { command.update!(token: form.token, attributes: { "name" => "Expired" }) }
      end
      assert_equal before, connection.reload.attributes
    end
  end

  test "unknown endpoint status and credential document fields cannot bypass the contract" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      [ { "base_url" => "https://example.com" }, { "status" => "good" }, { "credentials" => { "access_token" => "hidden" } },
        { "name" => "" }, { "sync_start_date" => "2026-02-31" }, { "access_token" => "token\nheader" },
        { "access_token" => "x" * (Configuration::MAX_SECRET_BYTES + 1) } ].each do |attributes|
        assert_raises(ArgumentError) { command.update!(token: form.token, attributes: attributes) }
        assert_equal before, connection.reload.attributes
      end
    end
  end

  test "pending work and an expired lease both require resolution before configuration changes" do
    with_connection do |connection, actor|
      sync = connection.syncs.create!
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      assert_raises(Store::Busy) { command.update!(token: form.token, attributes: { "name" => "Busy" }) }
      assert_equal before, connection.reload.attributes
      sync.update!(status: "completed", completed_at: Time.current)
      connection.update!(lease_owner: "abandoned", lease_expires_at: 1.hour.ago)
      form = command.form
      before = connection.reload.attributes
      assert_raises(Store::Busy) { command.update!(token: form.token, attributes: { "access_token" => "Busy" }) }
      assert_equal before, connection.reload.attributes
    end
  end

  test "opening the editor does not clear an uncertain exchange and replacement cannot bypass it" do
    with_connection do |connection, actor|
      connection.update!(status: "requires_update", credential_state: { "status" => "uncertain", "attempt_id" => SecureRandom.uuid })
      command = Configuration.new(connection: connection, actor: actor)
      before = connection.reload.attributes
      form = command.form
      assert_equal before, connection.reload.attributes
      assert_raises(Configuration::Conflict) { command.update!(token: form.token, attributes: { "access_token" => "unproven" }) }
      assert_equal before, connection.reload.attributes
      command.update!(token: form.token, attributes: { "name" => "Needs attention" })
      assert connection.reload.requires_update?
      assert_equal before.fetch("credential_state"), connection.credential_state
    end
  end

  test "static reauthorization restores status only for a different explicitly supplied credential" do
    with_connection do |connection, actor|
      connection.update!(status: "requires_update")
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      command.update!(token: form.token, attributes: { "access_token" => "original-token" })
      assert connection.reload.requires_update?
      command.update!(token: form.token, attributes: { "access_token" => "replacement-token" })
      assert connection.reload.good?
      assert_equal 1, connection.credential_revision
    end
  end

  test "native configuration preserves the original migration mapping and legacy credential bytes" do
    with_connection do |connection, actor|
      item = actor.family.up_items.create!(name: "Legacy Up", access_token: "retained-legacy-token")
      control = ProviderMigrationControl.create!(family: actor.family, provider_key: "up", legacy_type: "UpItem", legacy_id: item.id,
        provider_connection: connection, state: "active", writer_epoch: 1)
      mapping = control.provider_migration_mappings.create!(family: actor.family, role: "connection", legacy_type: "UpItem", legacy_id: item.id,
        provider_connection: connection)
      before = [ item.reload.attributes, control.reload.attributes, mapping.reload.attributes ]
      command = Configuration.new(connection: connection, actor: actor)
      command.update!(token: command.form.token, attributes: { "access_token" => "native-replacement" })
      assert_equal before, [ item.reload.attributes, control.reload.attributes, mapping.reload.attributes ]
      assert_equal "native-replacement", connection.reload.credentials.fetch("access_token")
      control.update!(state: "retired")
      assert command.form.token
      control.update!(state: "rollback_pending")
      assert_raises(Configuration::Conflict) { command.form }
    end
  end

  test "a connection cannot become editable through a missing or changed native mapping" do
    with_connection do |connection, actor|
      control = ProviderMigrationControl.create!(family: actor.family, provider_key: "up", legacy_type: "UpItem", legacy_id: SecureRandom.uuid,
        provider_connection: connection, state: "active")
      command = Configuration.new(connection: connection, actor: actor)
      assert_raises(Configuration::Conflict) { command.form }
      control.update!(state: "shadow")
      assert_raises(Configuration::Conflict) { command.form }
    end
  end

  test "a live credential session excludes administrative replacement across database sessions" do
    skip "requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      Store.new(connection: connection).with_session_lock do
        outcome = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            begin
              command.update!(token: form.token, attributes: { "access_token" => "racing" })
              :unexpected
            rescue Store::Busy
              :busy
            end
          end
        end
        begin
          assert_equal :busy, Timeout.timeout(10) { outcome.value }
        ensure
          outcome.kill if outcome.alive?
          outcome.join
        end
      end
      assert_equal before, connection.reload.attributes
      command.update!(token: form.token, attributes: { "access_token" => "after-release" })
      assert_equal "after-release", connection.reload.credentials.fetch("access_token")
    end
  end

  test "a copied connection cannot become newly native by losing its control" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      connection.update!(metadata: { "legacy_type" => "UpItem", "legacy_id" => SecureRandom.uuid })
      assert_raises(Configuration::Conflict) { command.form }

      connection.update!(metadata: {})
      control = ProviderMigrationControl.create!(family: actor.family, provider_key: "up", legacy_type: "UpItem",
        legacy_id: SecureRandom.uuid, state: "active")
      control.provider_migration_mappings.create!(family: actor.family, role: "connection", legacy_type: "UpItem",
        legacy_id: control.legacy_id, provider_connection: connection)
      assert_raises(Configuration::Conflict) { command.form }
    end
  end

  test "administrative replacement cannot enter from an enclosing transaction or credential session" do
    with_connection do |connection, actor|
      command = Configuration.new(connection: connection, actor: actor)
      form = command.form
      before = connection.reload.attributes
      assert_raises(ArgumentError) { ProviderConnection.transaction { command.update!(token: form.token, attributes: { "name" => "Rolled back" }) } }
      Store.new(connection: connection).with_session_lock do
        assert_raises(Store::Busy) { command.update!(token: form.token, attributes: { "name" => "Nested" }) }
      end
      assert_equal before, connection.reload.attributes
    end
  end

  { "mercury" => "https://api.mercury.com/api/v1", "brex" => "https://api.brex.com" }.each do |key, endpoint|
    test "#{key} opts in to token replacement while its endpoint remains immutable" do
      with_connection(provider_key: key, credentials: { "token" => "original-token" }, settings: { "base_url" => endpoint }) do |connection, actor|
        Provider::AccountData::Registry.declared_adapter(key).stubs(:native_ready?).returns(true)
        command = Configuration.new(connection: connection, actor: actor)
        form = command.form
        assert_equal [ "token" ], form.credential_fields
        assert_raises(ArgumentError) { command.update!(token: form.token, attributes: { "base_url" => "https://elsewhere.example" }) }
        command.update!(token: form.token, attributes: { "token" => "new-#{key}-token" })
        assert_equal "new-#{key}-token", connection.reload.credentials.fetch("token")
        assert_equal endpoint, connection.settings.fetch("base_url")
      end
    end
  end

  private
    def with_connection(**attributes)
      with_provider_encryption do
        family = Family.create!(name: "Native configuration")
        actor = family.users.create!(email: "native-config-#{SecureRandom.uuid}@example.com", password: "configuration-password", role: "admin")
        connection = create_provider_connection(**{ family: family, credentials: { "access_token" => "original-token" } }.merge(attributes))
        yield connection, actor
      ensure
        if family
          ProviderMigrationMapping.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.provider_connections.each do |row|
            row.update!(lease_sync_id: nil, lease_owner: nil, lease_expires_at: nil)
            row.syncs.destroy_all
            row.reload.destroy!
          end
          family.up_items.destroy_all
          family.users.destroy_all
          family.destroy!
        end
      end
    end
end
