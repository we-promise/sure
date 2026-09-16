# A copied token is bound to the deployment that selected its Plaid application.
# This proves configuration provenance only, never upstream token validity or
# acceptance of the legacy transaction cursor/cache.
class Provider::AccountData::Plaid::DeploymentBinding
  KEY = "plaid_deployment_binding".freeze
  FORMAT = "plaid-deployment-binding/v1".freeze
  MAX_BYTES = 4_096
  MAX_CREDENTIAL_BYTES = 65_536
  KEYS = %w[access_token_fingerprint application_fingerprint captured_at client_id_fingerprint copy_run_id environment family_id format legacy_id plaid_item_id region].freeze
  ENVIRONMENTS = %w[sandbox development production].freeze

  def self.capture(projection:, copy_run_id:)
    unless projection.provider_key == "plaid" && projection.kind == :item && projection.source_type == "PlaidItem"
      conflict!
    end
    region = projection.settings.fetch("plaid_region")
    application = configured_application(region: region)
    verify_loaded_configuration!(application)
    document = {
      "format" => FORMAT, "legacy_id" => projection.source_id, "family_id" => projection.identity.fetch("family_id"), "copy_run_id" => copy_run_id,
      "plaid_item_id" => projection.identity.fetch("plaid_id"), "region" => region,
      "environment" => application.fetch(:environment), "captured_at" => Time.current.utc.iso8601(9),
      "client_id_fingerprint" => fingerprint(application.fetch(:client_id), purpose: "client-id"),
      "application_fingerprint" => fingerprint(application, purpose: "application"),
      "access_token_fingerprint" => fingerprint(credential!(projection.credentials.fetch("access_token")), purpose: "access-token")
    }
    validate!(document, legacy_id: projection.source_id, family_id: projection.identity.fetch("family_id"), region: region, copy_run_id: copy_run_id)
    copy(document)
  rescue KeyError, TypeError, ArgumentError, NoMethodError
    conflict!
  end

  # Pure validation: original item fields remain independently compared by the
  # copier. Callers supply the identity from that typed source projection.
  def self.validate!(document, legacy_id:, family_id:, region:, copy_run_id: nil)
    shape!(document)
    unless document["legacy_id"] == legacy_id && document["family_id"] == family_id && document["region"] == region &&
        (copy_run_id.nil? || document["copy_run_id"] == copy_run_id)
      conflict!
    end
    document
  end

  def self.configured_application(region:)
    configuration = configuration_for(region)
    Setting.uncached do
      application = { client_id: configuration.config_value(:client_id), secret: configuration.config_value(:secret),
        region: region, environment: configuration.config_value(:environment) }
      application!(application)
      application
    end
  rescue NoMethodError, KeyError, ArgumentError, TypeError
    conflict!
  end

  def self.verify_application!(document, application:, check_legacy_configuration: false)
    shape!(document)
    normalized = application!(application)
    conflict! unless [ true, false ].include?(check_legacy_configuration)
    verify_loaded_configuration!(normalized) if check_legacy_configuration
    unless document["region"] == normalized[:region] && document["environment"] == normalized[:environment] &&
        document["client_id_fingerprint"] == fingerprint(normalized[:client_id], purpose: "client-id") &&
        document["application_fingerprint"] == fingerprint(normalized, purpose: "application")
      conflict!
    end
    true
  rescue NoMethodError, KeyError, ArgumentError, TypeError
    conflict!
  end

  # Cheap live verification. Factory capture additionally compares this small
  # projected binding with the immutable archive; each request rechecks settings,
  # application values and the mapping descriptor without decrypting that archive.
  def self.verify_connection!(connection:, application:)
    document = connection.settings[KEY]
    if document.nil?
      if connection.metadata.values_at("legacy_type", "legacy_id").any?(&:present?) ||
          (connection.persisted? && (ProviderMigrationControl.where(provider_connection_id: connection.id).exists? ||
            ProviderMigrationMapping.where(provider_connection_id: connection.id).exists?))
        conflict!
      end
      return application
    end
    verify_identity!(document, family_id: connection.family_id, external_id: connection.external_id,
      region: connection.region, environment: connection.environment, metadata: connection.metadata,
      credentials: connection.credentials)
    verify_application!(document, application: application)
    application
  rescue Provider::AccountData::MigrationCopier::Conflict
    stale!
  end

  def self.build(connection:, observed_at:, external_accounts: nil)
    reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "plaid")
    row = reader.item
    unless row
      conflict! if connection.settings[KEY]
      return nil
    end
    document = row.archive.fetch("auxiliary_inputs").fetch(KEY)
    validate!(document, legacy_id: row.context.fetch("legacy_id"), family_id: connection.family_id,
      region: row.attributes.fetch("plaid_region"), copy_run_id: row.context.fetch("copy_run_id"))
    unless document == connection.settings[KEY] && document["plaid_item_id"] == row.attributes.fetch("plaid_id") &&
        document["access_token_fingerprint"] == fingerprint(credential!(row.attributes.fetch("access_token")), purpose: "access-token")
      conflict!
    end
    verify_connection!(connection: connection, application: configured_application(region: connection.region))
    copy("binding" => document, "provenance" => row.context)
  rescue Provider::AccountData::MigrationCopier::Conflict, KeyError, ArgumentError, TypeError
    stale!
  end

  def self.live_input(connection:)
    { "item" => Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "plaid").item_descriptor }
  end

  # The factory receives data only. It must not query Rails settings, mappings or
  # retained archives; the runtime collector already admitted those inputs.
  def self.verify_factory!(snapshot:, credentials:, settings:, context:)
    details = context.fetch(:connection_details).with_indifferent_access
    metadata = (details[:metadata] || {}).with_indifferent_access
    if snapshot.nil?
      conflict! if settings.with_indifferent_access[KEY] || metadata.values_at(:legacy_type, :legacy_id).any?(&:present?)
      return true
    end
    unless snapshot.is_a?(Hash) && snapshot.keys.sort == %w[binding provenance] && snapshot["provenance"].is_a?(Hash)
      conflict!
    end
    document = snapshot.fetch("binding")
    provenance = snapshot.fetch("provenance")
    unless document == settings.with_indifferent_access[KEY] && provenance["provider_connection_id"] == details[:id] &&
        provenance["family_id"] == details[:family_id] && provenance["legacy_id"] == metadata[:legacy_id] &&
        provenance["provider_key"] == "plaid" && provenance["role"] == "connection" &&
        document["copy_run_id"] == provenance["copy_run_id"]
      conflict!
    end
    verify_identity!(document, family_id: details[:family_id], external_id: details[:external_id],
      region: context.fetch(:region), environment: context.fetch(:environment), metadata: metadata, credentials: credentials)
    verify_application!(document, application: context.fetch(:application_credentials))
  rescue Provider::AccountData::MigrationCopier::Conflict, KeyError, ArgumentError, TypeError
    stale!
  end

  class << self
    private
      def verify_identity!(document, family_id:, external_id:, region:, environment:, metadata:, credentials:)
        validate!(document, legacy_id: metadata.fetch("legacy_id"), family_id: family_id, region: region)
        unless metadata["legacy_type"] == "PlaidItem" && document["plaid_item_id"] == external_id && document["environment"] == environment &&
            document["access_token_fingerprint"] == fingerprint(credential!(credentials.with_indifferent_access.fetch(:access_token)), purpose: "access-token")
          conflict!
        end
      rescue KeyError, ArgumentError, TypeError
        conflict!
      end

      def shape!(document)
        unless document.is_a?(Hash) && document.keys.sort == KEYS && document["format"] == FORMAT &&
            %w[us eu].include?(document["region"]) && ENVIRONMENTS.include?(document["environment"]) &&
            %w[legacy_id family_id copy_run_id].all? { |key| document[key].is_a?(String) && document[key].match?(Provider::AccountData::LegacyWriterFence::UUID) } &&
            document["plaid_item_id"].is_a?(String) && document["plaid_item_id"].present? && document["plaid_item_id"].bytesize <= 1_024 &&
            %w[access_token_fingerprint application_fingerprint client_id_fingerprint].all? { |key| document[key].is_a?(String) && document[key].match?(/\A[0-9a-f]{64}\z/) } &&
            document["captured_at"].is_a?(String) && document["captured_at"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z\z/) &&
            JSON.generate(document).bytesize <= MAX_BYTES
          conflict!
        end
        Time.iso8601(document.fetch("captured_at"))
      rescue TypeError, ArgumentError
        conflict!
      end

      def application!(value)
        unless value.is_a?(Hash)
          conflict!
        end
        values = value.with_indifferent_access
        unless %w[us eu].include?(values[:region]) && ENVIRONMENTS.include?(values[:environment])
          conflict!
        end
        { client_id: credential!(values[:client_id]), secret: credential!(values[:secret]),
          region: values[:region], environment: values[:environment] }
      end

      def credential!(value)
        conflict! unless value.is_a?(String) && value.present? && value.bytesize <= MAX_CREDENTIAL_BYTES
        value
      end

      def configuration_for(region)
        case region
        when "us" then Provider::PlaidAdapter
        when "eu" then Provider::PlaidEuAdapter
        else conflict!
        end
      end

      def verify_loaded_configuration!(application)
        loaded = application[:region] == "us" ? Rails.application.config.plaid : Rails.application.config.plaid_eu
        return unless loaded
        unless loaded.server_index == ::Plaid::Configuration::Environment.fetch(application.fetch(:environment)) &&
            loaded.api_key["PLAID-CLIENT-ID"] == application[:client_id] && loaded.api_key["PLAID-SECRET"] == application[:secret]
          conflict!
        end
      end

      def fingerprint(value, purpose:)
        Provider::AccountData::RuntimeInputs.fingerprint(value, purpose: "#{FORMAT}/#{purpose}")
      end

      def copy(value)
        Provider::AccountData::MigrationManifest.copy_value(value)
      end

      def conflict!
        raise Provider::AccountData::MigrationCopier::Conflict,
          "Plaid deployment binding is missing or changed; explicit recopy or application rebind is required", cause: nil
      end

      def stale!
        raise Provider::AccountData::StaleWriter, "Plaid deployment binding or application changed", cause: nil
      end
  end
end
