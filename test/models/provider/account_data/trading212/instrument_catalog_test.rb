require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Trading212::InstrumentCatalogTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Catalog = Provider::AccountData::Trading212::InstrumentCatalog

  test "production construction supplies the archived catalog when a fresh catalog request fails" do
    with_catalog do |_item, control, connection|
      client, grant, adapter = construct(connection)
      account = adapter.normalize_account(id: "account", totalValue: "100", cash: { availableToTrade: "20" })
      client.expects(:fetch_orders_page).with(cursor: nil).returns(page([]))
      first, = grant.capture_request { adapter.fetch_activities(account: account) }
      client.expects(:fetch_instruments_page).raises(Provider::Trading212::ApiError.new("Unavailable"))
      client.expects(:fetch_dividends_page).with(cursor: nil).returns(page([ dividend ]))

      captured, proof = grant.capture_request { adapter.fetch_activities(account: account, cursor: first.next_cursor) }

      assert_equal "Retained Apple", captured.records.sole[:security][:name]
      assert_equal BigDecimal("-2.50"), captured.records.sole[:amount]
      assert_equal "instrument_catalog_unavailable_cached_metadata_used", captured.warnings.sole.fetch("code")
      assert grant.snapshot.dig("runtime_inputs", "frozen_context", "trading212_instrument_catalog").present?
      assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: proof, require_runtime_inputs: true)
      refute_includes JSON.generate(proof), "Retained Apple"
      assert_equal 1, control.provider_migration_mappings.count
      assert_empty connection.syncs
    end
  end

  test "live provenance checks avoid payload reads and reject a changed source checksum before HTTP" do
    with_catalog do |_item, control, connection|
      _client, grant, _adapter = construct(connection)
      IngestionBatch.any_instance.expects(:payload).never
      assert grant.verify!
      mapping = control.provider_migration_mappings.find_by!(role: "connection")
      mapping.update_columns(source_checksum: "v1-#{'0' * 64}")

      assert_raises(Provider::AccountData::StaleWriter) do
        grant.capture_request { flunk "Changed retained provenance reached the provider" }
      end
    end
  end

  test "successful live instruments override the fallback without modifying original archive evidence" do
    with_catalog do |_item, control, connection|
      before = control.provider_migration_mappings.order(:id).map(&:attributes)
      client, grant, adapter = construct(connection)
      account = adapter.normalize_account(id: "account", totalValue: "100", cash: { availableToTrade: "20" })
      client.expects(:fetch_orders_page).with(cursor: nil).returns(page([]))
      first, = grant.capture_request { adapter.fetch_activities(account: account) }
      client.expects(:fetch_instruments_page).returns(page([ { ticker: "AAPL_US_EQ", shortName: "Fresh Apple" } ]))
      client.expects(:fetch_dividends_page).with(cursor: nil).returns(page([ dividend ]))

      captured, = grant.capture_request { adapter.fetch_activities(account: account, cursor: first.next_cursor) }

      assert_equal "Fresh Apple", captured.records.sole[:security][:name]
      assert_empty captured.warnings
      assert_equal before, control.provider_migration_mappings.order(:id).map(&:attributes)
      assert_equal "Retained Apple", Catalog.build(connection: connection, observed_at: Time.current).fetch("instruments").sole.fetch("shortName")
    end
  end

  test "missing legacy catalog and empty catalog remain explicit distinct inputs" do
    [ nil, [] ].each do |raw|
      with_catalog(raw: raw) do |_item, _control, connection|
        snapshot = Catalog.build(connection: connection, observed_at: Time.current)
        assert_equal raw.nil? ? "absent" : "retained", snapshot.fetch("availability")
        assert_empty Catalog.instruments(snapshot)
        assert snapshot.fetch("source").present?
      end
    end
    with_provider_encryption do
      connection = create_provider_connection(provider_key: "trading212")
      snapshot = Catalog.build(connection: connection, observed_at: Time.current)
      assert_nil snapshot.fetch("source")
      assert_equal "absent", snapshot.fetch("availability")
    ensure
      connection&.destroy!
    end
  end

  test "malformed and duplicate retained instruments cannot silently become an empty fallback" do
    [ { "ticker" => "AAPL_US_EQ" }, [ nil ], [ { "ticker" => "" } ],
      [ { "ticker" => "AAPL_US_EQ" }, { "ticker" => "AAPL_US_EQ" } ],
      [ { "ticker" => "AAPL_US_EQ", "shortName" => { "private" => "unexpected" } } ] ].each do |raw|
      with_catalog(raw: raw) do |_item, _control, connection|
        error = assert_raises(Provider::AccountData::InvalidResponse) { Catalog.build(connection: connection, observed_at: Time.current) }
        refute_includes error.message, "unexpected"
      end
    end
  end

  private
    def with_catalog(raw: [ { "ticker" => "AAPL_US_EQ", "shortName" => "Retained Apple" } ])
      with_provider_encryption do
        item = Trading212Item.create!(family: families(:dylan_family), name: "Catalog source", currency: "EUR",
          api_key: "key", api_secret: "secret", raw_instruments_payload: raw)
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "trading212", legacy_item_id: item.id)
        control = nil
        10.times do
          control = copier.run_quiesced
          break if control.high_water_mark["phase"] == "verified"
        end
        assert control.quiescing?
        assert_equal "verified", control.high_water_mark["phase"]
        assert_equal "quiesced", control.audit_results["copy_mode"]
        assert_equal true, control.audit_results["declared_writer_fence_held"]
        connection = control.provider_connection
        # Test-only native ownership exercises the actual factory/grant boundary;
        # preparation and operational cutover remain separate commands.
        control.update!(state: "active")
        connection.update!(status: "good")
        yield item, control, connection
      ensure
        cleanup_catalog_copy(item) if item
      end
    end

    def cleanup_catalog_copy(item)
      # Item-only version of IdentityBootstrapTestHelper's cleanup: no financial
      # account was created, and source destruction must not invoke remote APIs.
      control = ProviderMigrationControl.find_by(legacy_type: "Trading212Item", legacy_id: item.id)
      connection = control&.provider_connection
      connection&.provider_sync_checkpoints&.delete_all
      ProviderMigrationAccountBinding.where(family_id: control.family_id,
        provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
      connection&.ingestion_batches&.delete_all
      control&.provider_migration_mappings&.delete_all
      control&.delete
      connection&.destroy!
      item.delete
    end

    def construct(connection)
      client = mock("Trading 212 transport")
      Provider::Trading212.expects(:new).with(api_key: "key", api_secret: "secret", environment: "live").returns(client)
      Provider::AccountData::Registry.stubs(:fetch).with("trading212").returns(Provider::AccountData::Trading212)
      grant = Provider::AccountData::RequestGrant.new(connection)
      adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.utc(2026, 9, 15, 12), request_grant: grant)
      [ client, grant, adapter ]
    end

    def page(items)
      { items: items, next_cursor: nil }
    end

    def dividend
      { reference: "dividend", ticker: "AAPL_US_EQ", amount: "2.50", paidOn: "2026-09-14" }
    end
end
