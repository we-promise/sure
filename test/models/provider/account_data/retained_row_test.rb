require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::RetainedRowTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Reader = Provider::AccountData::RetainedRow

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "new native sources have no invented retained input" do
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "trading212")
      external = create_external_account(connection)
      reader = Reader.new(connection: connection, provider_key: "trading212")
      assert_nil reader.item
      assert_nil reader.item_descriptor
      assert_nil reader.account(external)
      assert_nil reader.account_descriptor(external)
    ensure
      connection&.destroy!
    end
  end

  test "verified archived rows and descriptors preserve source identity without reading live legacy data" do
    with_copy do |item, source, control, external|
      reader = Reader.new(connection: control.provider_connection, provider_key: "trading212")
      before = [ control.attributes, control.provider_connection.attributes, external.attributes ]
      row = reader.item
      account = reader.account(external)

      assert_equal [ { "ticker" => "AAPL_US_EQ", "shortName" => "Private catalog name" } ], row.attributes.fetch("raw_instruments_payload")
      assert_equal row.context, reader.item_descriptor
      assert_equal account.context, reader.account_descriptor(external)
      assert_equal item.id, row.context.fetch("legacy_id")
      assert_equal source.id, account.context.fetch("legacy_id")
      assert_equal external.id, account.context.fetch("target_id")
      assert_equal control.high_water_mark.fetch("copy_run_id"), row.context.fetch("copy_run_id")
      assert_equal Provider::AccountData::MigrationValue.dump(row.archive).bytesize, row.byte_size
      assert row.attributes.frozen?
      assert row.context.frozen?
      assert row.archive.frozen?
      refute_includes row.inspect, "Private catalog name"
      refute_includes row.context.to_json, "private-key"
      assert_equal before, [ control.reload.attributes, control.provider_connection.reload.attributes, external.reload.attributes ]

      item.update_columns(raw_instruments_payload: [ { "ticker" => "LATER" } ])
      assert_equal row, Reader.new(connection: control.provider_connection, provider_key: "trading212").item
    end
  end

  test "descriptor reads do not decrypt archived payloads" do
    with_copy do |_item, _source, control, external|
      IngestionBatch.any_instance.expects(:payload).never
      reader = Reader.new(connection: control.provider_connection, provider_key: "trading212")
      assert reader.item_descriptor.fetch("source_checksum").start_with?("v1-")
      assert_equal "external_account", reader.account_descriptor(external).fetch("role")
    end
  end

  test "foreign sources cannot be used as retained inputs" do
    with_copy do |_item, _source, control, _external|
      foreign_connection = create_provider_connection(provider_key: "trading212", family: families(:empty))
      foreign = create_external_account(foreign_connection)
      reader = Reader.new(connection: control.provider_connection, provider_key: "trading212")
      assert_raises(Provider::AccountData::StaleWriter) { reader.account(foreign) }
      assert_raises(ArgumentError) { Reader.new(connection: control.provider_connection, provider_key: "wise") }
    ensure
      foreign_connection&.destroy!
    end
  end

  test "shadow copies and copies without a fenced verification audit cannot seed runtime history" do
    with_copy(quiesced: false) do |_item, _source, control, _external|
      assert control.shadow?
      assert_raises(Provider::AccountData::StaleWriter) do
        Reader.new(connection: control.provider_connection, provider_key: "trading212")
      end
    end
    with_copy do |_item, _source, control, _external|
      control.update!(audit_results: control.audit_results.merge("declared_writer_fence_held" => false))
      assert_raises(Provider::AccountData::StaleWriter) do
        Reader.new(connection: control.provider_connection, provider_key: "trading212")
      end
    end
  end

  test "unverified copies and missing mappings fail instead of becoming empty history" do
    with_copy do |_item, _source, control, external|
      mapping = control.provider_migration_mappings.find_by!(external_account: external)
      mapping.update_columns(verified_at: nil)
      assert_raises(Provider::AccountData::StaleWriter) do
        Reader.new(connection: control.provider_connection, provider_key: "trading212").account(external)
      end
      mapping.delete
      assert_raises(Provider::AccountData::StaleWriter) do
        Reader.new(connection: control.provider_connection, provider_key: "trading212").account_descriptor(external)
      end
      control.update!(state: "copying")
      assert_raises(Provider::AccountData::StaleWriter) do
        Reader.new(connection: control.provider_connection, provider_key: "trading212")
      end
    end
  end

  test "corrupt and over-budget archives are rejected without returning partial values" do
    with_copy do |_item, _source, control, _external|
      reader = Reader.new(connection: control.provider_connection, provider_key: "trading212")
      with_reader_byte_limit(64) do
        assert_raises(Provider::AccountData::StaleWriter) { reader.item }
      end
      batch = control.provider_connection.ingestion_batches.find_by!(external_account_id: nil, sequence: 0)
      batch.update_columns(payload: batch.payload.merge("data" => Base64.strict_encode64("private-corruption")))
      error = assert_raises(Provider::AccountData::StaleWriter) { reader.item }
      refute_includes error.message, "private-corruption"
      assert_nil error.cause
    end
  end

  private
    def with_reader_byte_limit(value)
      previous = Reader::MAX_BYTES
      Reader.send(:remove_const, :MAX_BYTES)
      Reader.const_set(:MAX_BYTES, value)
      yield
    ensure
      Reader.send(:remove_const, :MAX_BYTES)
      Reader.const_set(:MAX_BYTES, previous)
    end

    def with_copy(quiesced: true)
      with_provider_encryption do
        item = Trading212Item.create!(family: families(:dylan_family), name: "Retained catalog", currency: "EUR",
          api_key: "private-key", api_secret: "private-secret", raw_instruments_payload: [ { "ticker" => "AAPL_US_EQ", "shortName" => "Private catalog name" } ])
        source = item.trading212_accounts.create!(trading212_account_id: "account", currency: "EUR", name: "Investments")
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "trading212", legacy_item_id: item.id)
        control = nil
        10.times do
          control = (quiesced ? copier.run_quiesced : copier.run).reload
          break if control.high_water_mark["phase"] == "verified"
        end
        assert_equal "verified", control.high_water_mark["phase"]
        yield item, source, control, control.provider_connection.external_accounts.sole
      ensure
        if control
          connection = control.provider_connection
          ProviderMigrationAccountBinding.where(provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all
          connection.provider_sync_checkpoints.delete_all
          connection.ingestion_batches.delete_all
          control.provider_migration_mappings.delete_all
          control.delete
          connection.destroy!
        end
        source&.delete
        item&.delete
        clear_enqueued_jobs
      end
    end
end
