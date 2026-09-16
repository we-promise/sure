# Read-only access to a verified copied row. Runtime collectors own the meaning
# of its fields; a retained row proves neither source coverage nor writer authority.
class Provider::AccountData::RetainedRow
  class TooLarge < Provider::AccountData::StaleWriter; end
  FORMAT = "retained-provider-row/v1".freeze
  MAX_BYTES = 32 * 1024 * 1024
  MAX_CHUNKS = 1_024
  READABLE_STATES = %w[quiescing active retired].freeze
  Result = Data.define(:attributes, :context, :archive, :byte_size) do
    def inspect
      "#<#{self.class.name} bytes=#{byte_size}>"
    end
  end

  def initialize(connection:, provider_key:, max_bytes: MAX_BYTES)
    unless max_bytes.is_a?(Integer) && (1..MAX_BYTES).cover?(max_bytes)
      raise ArgumentError, "Retained input requires a bounded read"
    end
    @max_bytes = max_bytes
    unless connection.is_a?(ProviderConnection) && connection.persisted? && connection.provider_key == provider_key
      raise ArgumentError, "Retained input requires its provider connection"
    end
    @connection = ProviderConnection.find_by!(id: connection.id, family_id: connection.family_id, provider_key: provider_key)
    @manifest = Provider::AccountData::MigrationManifest.for(provider_key)
    @control = ProviderMigrationControl.find_by(provider_connection_id: connection.id)
    validate_control!
  rescue ActiveRecord::RecordNotFound
    raise Provider::AccountData::StaleWriter, "Retained input connection changed", cause: nil
  end

  def item
    read(:item, item_mapping)
  end

  def account(external)
    read(:account, account_mapping(external))
  end

  # These small descriptors can join the live request fingerprint. Financial
  # requests must not decrypt and parse all retained history before every page.
  def item_descriptor
    descriptor(item_mapping)
  end

  def account_descriptor(external)
    descriptor(account_mapping(external))
  end

  private
    attr_reader :connection, :manifest, :control

    def validate_control!
      if control.nil?
        if connection.metadata["legacy_id"].present? || connection.metadata["legacy_type"].present? ||
            ProviderMigrationMapping.where(provider_connection_id: connection.id).exists?
          raise Provider::AccountData::StaleWriter, "Retained connection mapping is missing"
        end
        return
      end
      progress = control.high_water_mark
      unless control.family_id == connection.family_id && control.provider_key == manifest.provider_key &&
          control.legacy_type == manifest.item_type && READABLE_STATES.include?(control.state) &&
          control.copy_version == Provider::AccountData::MigrationManifest::VERSION &&
          progress["phase"] == "verified" && progress["mode"] == "quiesced" && progress["copy_run_id"].is_a?(String) &&
          progress["copy_run_id"].match?(Provider::AccountData::LegacyWriterFence::UUID) &&
          control.audit_results["copy_run_id"] == progress["copy_run_id"] && control.audit_results["snapshot_checksums_verified"] == true &&
          control.audit_results["copy_mode"] == "quiesced" && control.audit_results["declared_writer_fence_held"] == true
        raise Provider::AccountData::StaleWriter, "Retained input requires its verified original copy"
      end
    end

    def item_mapping
      return unless control
      rows = ProviderMigrationMapping.where(provider_migration_control_id: control.id, role: "connection").limit(2).to_a
      unless rows.one?
        raise Provider::AccountData::StaleWriter, "Retained connection mapping is missing or ambiguous"
      end
      validate_mapping!(rows.first, kind: :item, target_id: connection.id)
    end

    def account_mapping(external)
      unless external.is_a?(ExternalAccount) && external.persisted? && external.provider_connection_id == connection.id &&
          external.family_id == connection.family_id && external.provider_key == manifest.provider_key
        raise Provider::AccountData::StaleWriter, "Retained account belongs to another connection"
      end
      current = connection.external_accounts.find_by!(id: external.id, family_id: connection.family_id)
      rows = ProviderMigrationMapping.where(external_account_id: current.id).limit(2).to_a
      if rows.empty? && current.metadata["legacy_id"].blank? && current.metadata["legacy_type"].blank?
        return nil
      end
      unless control && rows.one?
        raise Provider::AccountData::StaleWriter, "Retained account mapping is missing or ambiguous"
      end
      validate_mapping!(rows.first, kind: :account, target_id: current.id)
    rescue ActiveRecord::RecordNotFound
      raise Provider::AccountData::StaleWriter, "Retained account identity changed", cause: nil
    end

    def validate_mapping!(mapping, kind:, target_id:)
      expected_type = kind == :item ? manifest.item_type : manifest.account_type
      expected_role = kind == :item ? "connection" : "external_account"
      expected_target = kind == :item ? mapping.provider_connection_id : mapping.external_account_id
      unless mapping.family_id == connection.family_id && mapping.provider_migration_control_id == control.id &&
          mapping.legacy_type == expected_type && mapping.role == expected_role && expected_target == target_id &&
          (kind != :item || mapping.legacy_id == control.legacy_id) && mapping.copied_at && mapping.verified_at &&
          mapping.source_checksum.is_a?(String) && mapping.source_checksum.match?(/\Av1-[0-9a-f]{64}\z/)
        raise Provider::AccountData::StaleWriter, "Retained source mapping changed or is unverified"
      end
      mapping
    end

    def descriptor(mapping)
      return unless mapping
      Provider::AccountData::MigrationManifest.copy_value(
        "format" => FORMAT, "provider_key" => manifest.provider_key, "family_id" => connection.family_id,
        "provider_connection_id" => connection.id, "control_id" => control.id,
        "copy_run_id" => control.high_water_mark.fetch("copy_run_id"), "manifest_version" => control.copy_version,
        "mapping_id" => mapping.id, "legacy_type" => mapping.legacy_type, "legacy_id" => mapping.legacy_id,
        "role" => mapping.role, "target_id" => mapping.role == "connection" ? mapping.provider_connection_id : mapping.external_account_id,
        "source_checksum" => mapping.source_checksum, "source_version" => mapping.source_version)
    end

    def read(kind, mapping)
      return unless mapping
      copier = Provider::AccountData::MigrationCopier.new(provider_key: manifest.provider_key, legacy_item_id: control.legacy_id)
      archive = copier.snapshot_for(mapping, max_bytes: @max_bytes, max_chunks: MAX_CHUNKS)
      expected_table = kind == :item ? manifest.item_table : manifest.account_table
      attributes = archive["attributes"]
      unless archive["format"] == Provider::AccountData::MigrationCopier::SNAPSHOT_FORMAT &&
          archive["manifest_version"] == control.copy_version && archive["provider_key"] == manifest.provider_key &&
          archive["source_type"] == mapping.legacy_type && archive["source_id"] == mapping.legacy_id &&
          archive["source_table"] == expected_table && archive["dispositions"] == manifest.dispositions(kind) &&
          attributes.is_a?(Hash) && attributes.keys.sort == manifest.columns(kind).sort && attributes["id"] == mapping.legacy_id &&
          (kind == :item ? attributes["family_id"] == connection.family_id : attributes[manifest.account_foreign_key] == control.legacy_id)
        raise Provider::AccountData::StaleWriter, "Retained archive does not describe the selected source"
      end
      bytes = Provider::AccountData::MigrationValue.dump(archive).bytesize
      Result.new(attributes: Provider::AccountData::MigrationManifest.copy_value(attributes), context: descriptor(mapping),
        archive: Provider::AccountData::MigrationManifest.copy_value(archive), byte_size: bytes).freeze
    rescue Provider::AccountData::MigrationCopier::SnapshotTooLarge
      raise TooLarge, "Retained archive exceeds its read bound", cause: nil
    rescue Provider::AccountData::MigrationCopier::Conflict, KeyError, TypeError, ArgumentError
      raise Provider::AccountData::StaleWriter, "Retained archive is missing, invalid or exceeds its bound", cause: nil
    end
end
