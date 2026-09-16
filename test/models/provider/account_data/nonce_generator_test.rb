require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::NonceGeneratorTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  test "committed nonces increase across instances and clock rollback" do
    with_connection do |connection|
      first = Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 100 })
      assert_equal "100", first.call
      assert_equal "101", first.call
      restarted = Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 50 })
      assert_equal "102", restarted.call
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "request_nonce")
      assert_equal "102", checkpoint.state.fetch("last_nonce")
      assert_provider_column_encrypted(checkpoint, :state, "last_nonce")
    end
  end

  test "first native nonce is greater than the archived legacy counter" do
    with_connection do |connection|
      control = ProviderMigrationControl.create!(family: connection.family, provider_connection: connection,
        provider_key: "kraken", legacy_type: "KrakenItem", legacy_id: SecureRandom.uuid, state: "active")
      connection.provider_sync_checkpoints.create!(stream: "legacy_state", scope_key: "KrakenItem:#{control.legacy_id}",
        state: { "format" => Provider::AccountData::MigrationCopier::SNAPSHOT_FORMAT,
          "columns" => Provider::AccountData::MigrationValue.encode("last_nonce" => 1000) })
      assert_equal "1001", Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 50 }).call
      control.update!(state: "retired")
      assert_equal "1002", Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 50 }).call
      control.update!(state: "rollback_pending")
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 50 }).call
      end
    end
  end

  test "a rolled-back financial transaction cannot roll back a consumed nonce" do
    with_connection do |connection|
      generator = Provider::AccountData::NonceGenerator.new(connection: connection, clock: -> { 100 })
      assert_raises(ArgumentError) { ProviderConnection.transaction { generator.call } }
      assert_equal "100", generator.call
    end
  end

  test "legacy and disabled connections cannot allocate native request state" do
    with_connection do |connection|
      connection.update!(status: "disabled")
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::NonceGenerator.new(connection: connection).call
      end
      connection.update!(status: "good")
      ProviderMigrationControl.create!(family: connection.family, provider_connection: connection,
        provider_key: "kraken", legacy_type: "KrakenItem", legacy_id: SecureRandom.uuid, state: "shadow")
      assert_raises(Provider::AccountData::StaleWriter) do
        Provider::AccountData::NonceGenerator.new(connection: connection).call
      end
      assert_empty connection.provider_sync_checkpoints
    end
  end

  private
    def with_connection
      with_provider_encryption do
        connection = create_provider_connection(provider_key: "kraken")
        begin
          yield connection
        ensure
          connection.provider_migration_control&.destroy!
          connection.reload.destroy!
        end
      end
    end
end
