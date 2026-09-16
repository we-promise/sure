require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Plaid::DeploymentBindingTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Binding = Provider::AccountData::Plaid::DeploymentBinding
  Copier = Provider::AccountData::MigrationCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "each region and environment has explicit immutable application and token provenance without plaintext secrets" do
    %w[us eu].product(%w[sandbox development production]).each do |region, environment|
      with_configuration(region: region, environment: environment) do |application|
        with_provider_encryption do
          source = projection(region: region)
          document = Binding.capture(projection: source, copy_run_id: SecureRandom.uuid)
          assert_equal region, document.fetch("region")
          assert_equal environment, document.fetch("environment")
          assert_equal source.source_id, document.fetch("legacy_id")
          assert_equal source.identity.fetch("family_id"), document.fetch("family_id")
          assert_equal "item-1", document.fetch("plaid_item_id")
          assert Binding.verify_application!(document, application: application.stringify_keys)
          assert_equal document, Provider::AccountData::MigrationValue.load(Provider::AccountData::MigrationValue.dump(document))
          assert document.frozen?
          %w[private-client private-secret private-token].each { |private_value| refute_includes document.inspect, private_value }
          assert_raises(FrozenError) { document["environment"] = "production" }
        end
      end
    end
  end

  test "EU capture never selects US credentials or mutates the cached SDK configuration" do
    with_configuration(region: "eu", environment: "production") do |application|
      Provider::PlaidAdapter.expects(:config_value).never
      Provider::PlaidEuAdapter.expects(:reload_configuration).never
      loaded = sdk_configuration(application)
      Rails.application.config.plaid_eu = loaded
      with_provider_encryption do
        document = Binding.capture(projection: projection(region: "eu"), copy_run_id: SecureRandom.uuid)
        assert_equal "production", document.fetch("environment")
        assert_same loaded, Rails.application.config.plaid_eu
      end
    end
  end

  test "a stale legacy SDK environment application or secret blocks capture instead of silently rebinding" do
    %i[environment client_id secret].each do |field|
      with_configuration(region: "us", environment: "production") do |application|
        changed = application.merge(field => (field == :environment ? "sandbox" : "different-private-value"))
        Rails.application.config.plaid = sdk_configuration(changed)
        Provider::PlaidAdapter.expects(:reload_configuration).never
        with_provider_encryption do
          error = assert_raises(Copier::Conflict) { Binding.capture(projection: projection, copy_run_id: SecureRandom.uuid) }
          refute_includes error.message, "different-private-value"
          refute_includes error.message, "private-secret"
          assert_nil error.cause
        end
      end
    end
  end

  test "application rotation and foreign source identities cannot inherit an existing binding" do
    with_configuration do |application|
      with_provider_encryption do
        source = projection
        document = Binding.capture(projection: source, copy_run_id: SecureRandom.uuid)
        { client_id: "replacement-client", secret: "replacement-secret", environment: "production", region: "eu" }.each do |field, value|
          assert_raises(Copier::Conflict) { Binding.verify_application!(document, application: application.merge(field => value)) }
        end
        assert_raises(Copier::Conflict) do
          Binding.validate!(document, legacy_id: SecureRandom.uuid, family_id: source.identity.fetch("family_id"), region: "us")
        end
        assert_raises(Copier::Conflict) do
          Binding.validate!(document, legacy_id: source.source_id, family_id: SecureRandom.uuid, region: "us")
        end
        assert_raises(Copier::Conflict) do
          Binding.validate!(document.merge("unknown" => "field"), legacy_id: source.source_id, family_id: source.identity.fetch("family_id"), region: "us")
        end
      end
    end
  end

  test "native construction uses its pinned application independently of a retired legacy SDK object" do
    with_configuration do |application|
      with_copied_item do |_item, _copier, _control, connection|
        document = connection.settings.fetch(Binding::KEY)
        Rails.application.config.plaid = sdk_configuration(application.merge(secret: "unrelated-legacy-secret"))
        assert Binding.verify_application!(document, application: application)
        assert_raises(Copier::Conflict) do
          Binding.verify_application!(document, application: application, check_legacy_configuration: true)
        end
        assert Binding.build(connection: connection, observed_at: Time.current)
        Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
        adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        assert_equal %w[transactions holdings activities], adapter.capabilities
      end
    end
  end

  test "missing credentials unsupported environment and oversized application inputs fail closed" do
    [ { secret: nil }, { client_id: "" }, { environment: "custom" }, { secret: "x" * (Binding::MAX_CREDENTIAL_BYTES + 1) } ].each do |changes|
      with_configuration(**changes) do
        assert_raises(Copier::Conflict) { Binding.configured_application(region: "us") }
      end
    end
    assert_raises(Copier::Conflict) { Binding.configured_application(region: "unknown") }
  end

  test "real quiesced copy supplies the immutable deployment used by production factory and request proof" do
    with_configuration(region: "eu", environment: "development") do |application|
      with_copied_item(region: "eu") do |item, copier, control, connection|
        binding = connection.settings.fetch(Binding::KEY)
        mapping = control.provider_migration_mappings.find_by!(role: "connection")
        archive = copier.snapshot_for(mapping)
        assert_equal "development", connection.environment
        assert_equal binding, archive.fetch("auxiliary_inputs").fetch(Binding::KEY)
        assert_equal item.access_token, archive.fetch("attributes").fetch("access_token")
        snapshot = Binding.build(connection: connection, observed_at: Time.current)
        assert_equal binding, snapshot.fetch("binding")
        assert_equal mapping.source_checksum, snapshot.dig("provenance", "source_checksum")
        assert snapshot.frozen?

        Provider::AccountData::Registry.stubs(:fetch).with("plaid").returns(Provider::AccountData::Plaid)
        adapter = Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        assert_equal [ "transactions" ], adapter.capabilities
        _, capture = adapter.request_grant.capture_request { :no_http }
        assert capture.dig("after", "runtime_inputs", "frozen_context", "plaid_deployment_binding").present?
        assert Provider::AccountData::RequestGrant.verify_capture!(connection: connection, capture: capture, require_runtime_inputs: true)

        Provider::PlaidEuAdapter.stubs(:config_value).with(:secret).returns("rotated-private-secret")
        assert_raises(Provider::AccountData::StaleWriter) do
          adapter.request_grant.capture_request { flunk "Changed application reached HTTP" }
        end
        assert_raises(Provider::AccountData::StaleWriter) do
          Provider::AccountData::Registry.build(connection, observed_at: Time.current)
        end
        assert_equal binding, connection.reload.settings.fetch(Binding::KEY)
        assert_equal archive, copier.snapshot_for(mapping)
        assert connection.disabled?
        assert_empty connection.syncs
        assert_empty connection.provider_sync_checkpoints.where(stream: "transactions")
        refute_includes capture.inspect, application.fetch(:secret)
      end
    end
  end

  test "factory archive proof cannot be replaced with self-consistent current settings" do
    with_configuration do |application|
      with_copied_item do |item, copier, control, connection|
        original = connection.settings.fetch(Binding::KEY)
        mapping = control.provider_migration_mappings.find_by!(role: "connection")
        archive = copier.snapshot_for(mapping)
        Provider::PlaidAdapter.stubs(:config_value).with(:secret).returns("replacement-secret")
        replacement = Binding.capture(projection: Provider::AccountData::MigrationManifest.for("plaid").extract_item(item.reload), copy_run_id: control.high_water_mark.fetch("copy_run_id"))
        connection.update!(settings: connection.settings.merge(Binding::KEY => replacement))
        assert_raises(Provider::AccountData::StaleWriter) { Binding.build(connection: connection, observed_at: Time.current) }
        assert_equal original, archive.fetch("auxiliary_inputs").fetch(Binding::KEY)
        assert_equal archive, copier.snapshot_for(mapping)
        refute_equal original, replacement
      end
    end
  end

  test "live descriptors pin retained evidence without decrypting the original archive for each request" do
    with_configuration do
      with_copied_item do |_item, _copier, control, connection|
        original = Binding.live_input(connection: connection)
        mapping = control.provider_migration_mappings.find_by!(role: "connection")
        Copier.any_instance.expects(:snapshot_for).never
        assert_equal original, Binding.live_input(connection: connection)
        mapping.update!(source_checksum: "v1-#{'a' * 64}")
        refute_equal original, Binding.live_input(connection: connection)
      end
    end
  end

  test "copied token and environment changes reject even when the current application is unchanged" do
    %i[token environment].each do |change|
      with_configuration do |application|
        with_copied_item do |_item, _copier, _control, connection|
          if change == :token
            connection.update!(credentials: connection.credentials.merge("access_token" => "replacement-token"))
          else
            connection.update!(environment: "production")
          end
          assert_raises(Provider::AccountData::StaleWriter) { Binding.verify_connection!(connection: connection, application: application) }
        end
      end
    end
  end

  test "same-run retry retains the original binding and capture timestamp" do
    with_configuration do
      with_copied_item(stop_after_first_pass: true) do |_item, copier, control, connection|
        assert_equal "verify", control.high_water_mark.fetch("phase")
        original = connection.settings.fetch(Binding::KEY)
        checksum = control.provider_migration_mappings.find_by!(role: "connection").source_checksum
        Binding.expects(:capture).never
        travel 1.minute do
          result = copier.run_quiesced
          assert_equal "verified", result.high_water_mark.fetch("phase")
        end
        assert_equal original, connection.reload.settings.fetch(Binding::KEY)
        assert_equal checksum, control.provider_migration_mappings.find_by!(role: "connection").source_checksum
        assert_nil control.reload.high_water_mark["plaid_binding_capture_pending"]
      end
    end
  end

  test "a shadow upgrade captures its new quiesced run without rewriting old unbound chunks" do
    with_configuration do
      with_copied_item(shadow: true) do |_item, copier, control, connection|
        assert_nil connection.environment
        assert_nil connection.settings[Binding::KEY]
        old_chunks = connection.ingestion_batches.order(:id).map { |batch| [ batch.id, batch.payload ] }
        assert_raises(Provider::AccountData::StaleWriter) { Binding.build(connection: connection, observed_at: Time.current) }
        finish_quiesced(copier)
        binding = connection.reload.settings.fetch(Binding::KEY)
        assert_equal control.reload.high_water_mark.fetch("copy_run_id"), binding.fetch("copy_run_id")
        assert_equal "sandbox", connection.environment
        old_chunks.each { |id, payload| assert_equal payload, IngestionBatch.find(id).payload }
        assert Binding.build(connection: connection, observed_at: Time.current)
      end
    end
  end

  test "explicit pre-proof restart creates a new binding while retaining the earlier run archive" do
    with_configuration do
      with_copied_item do |_item, copier, control, connection|
        original = connection.settings.fetch(Binding::KEY)
        old_chunks = connection.ingestion_batches.order(:id).map { |batch| [ batch.id, batch.payload ] }
        copier.run_quiesced(restart: true)
        finish_quiesced(copier)
        replacement = connection.reload.settings.fetch(Binding::KEY)
        refute_equal original.fetch("copy_run_id"), replacement.fetch("copy_run_id")
        assert_equal control.reload.high_water_mark.fetch("copy_run_id"), replacement.fetch("copy_run_id")
        assert_equal original.fetch("application_fingerprint"), replacement.fetch("application_fingerprint")
        old_chunks.each { |id, payload| assert_equal payload, IngestionBatch.find(id).payload }
        assert Binding.build(connection: connection, observed_at: Time.current)
      end
    end
  end

  test "crash before item publication preserves first capture admission but old unbound quiescence cannot infer it" do
    with_configuration do
      with_copied_item(shadow: true) do |_item, copier, control, connection|
        Binding.expects(:capture).once.raises(Copier::Conflict, "Simulated pre-publication failure")
        assert_raises(Copier::Conflict) { copier.run_quiesced }
        assert_equal true, control.reload.high_water_mark["plaid_binding_capture_pending"]
        assert_nil connection.reload.settings[Binding::KEY]
        Binding.unstub(:capture)
        finish_quiesced(copier)
        assert_equal control.reload.high_water_mark.fetch("copy_run_id"), connection.reload.settings.fetch(Binding::KEY).fetch("copy_run_id")
      end
      with_copied_item(shadow: true) do |_item, copier, control, connection|
        Binding.expects(:capture).once.raises(Copier::Conflict, "Simulated old interrupted copy")
        assert_raises(Copier::Conflict) { copier.run_quiesced }
        Binding.unstub(:capture)
        # Represents the original pre-binding protocol: no capture-admission marker.
        control.update!(high_water_mark: control.reload.high_water_mark.except("plaid_binding_capture_pending"))
        Binding.expects(:capture).never
        assert_raises(Copier::Conflict) { copier.run_quiesced }
        assert_nil connection.reload.settings[Binding::KEY]
      end
    end
  end

  private
    def with_configuration(region: "us", environment: "sandbox", client_id: "private-client", secret: "private-secret")
      before_us, before_eu = Rails.application.config.plaid, Rails.application.config.plaid_eu
      Rails.application.config.plaid = nil
      Rails.application.config.plaid_eu = nil
      configuration = region == "eu" ? Provider::PlaidEuAdapter : Provider::PlaidAdapter
      configuration.stubs(:config_value).with(:client_id).returns(client_id)
      configuration.stubs(:config_value).with(:secret).returns(secret)
      configuration.stubs(:config_value).with(:environment).returns(environment)
      yield({ client_id: client_id, secret: secret, region: region, environment: environment })
    ensure
      Rails.application.config.plaid, Rails.application.config.plaid_eu = before_us, before_eu
    end

    def sdk_configuration(application)
      ::Plaid::Configuration.new.tap do |config|
        config.server_index = ::Plaid::Configuration::Environment.fetch(application.fetch(:environment))
        config.api_key["PLAID-CLIENT-ID"] = application.fetch(:client_id)
        config.api_key["PLAID-SECRET"] = application.fetch(:secret)
      end
    end

    def projection(region: "us")
      source = PlaidItem.new(id: SecureRandom.uuid, family: families(:dylan_family), name: "Deployment proof",
        plaid_region: region, plaid_id: "item-1", access_token: "private-token")
      Provider::AccountData::MigrationManifest.for("plaid").extract_item(source)
    end

    def with_copied_item(region: "us", shadow: false, stop_after_first_pass: false)
      with_provider_encryption do
        item = PlaidItem.create!(family: families(:dylan_family), name: "Deployment copy", plaid_region: region,
          plaid_id: "item-#{SecureRandom.uuid}", access_token: "private-token")
        copier = Copier.new(provider_key: "plaid", legacy_item_id: item.id, batch_size: 1)
        control = nil
        10.times do
          control = (shadow ? copier.run : copier.run_quiesced).reload
          break if stop_after_first_pass
          break if shadow ? control.shadow? : control.high_water_mark["phase"] == "verified"
        end
        assert_equal(stop_after_first_pass ? "verify" : "verified", control.high_water_mark["phase"])
        assert(shadow ? control.shadow? : control.quiescing?)
        yield item, copier, control, control.provider_connection.reload
      ensure
        control ||= ProviderMigrationControl.find_by(legacy_type: "PlaidItem", legacy_id: item&.id)
        connection = control&.provider_connection
        connection&.provider_sync_checkpoints&.delete_all
        ProviderMigrationAccountBinding.where(family_id: control.family_id,
          provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
        connection&.ingestion_batches&.delete_all
        control&.provider_migration_mappings&.delete_all
        control&.delete
        connection&.destroy!
        item&.delete # No remote Plaid remove callback in fixture cleanup.
      end
    end

    def finish_quiesced(copier)
      result = nil
      10.times do
        result = copier.run_quiesced.reload
        break if result.high_water_mark["phase"] == "verified"
      end
      assert_equal "verified", result.high_water_mark.fetch("phase")
      result
    end
end
