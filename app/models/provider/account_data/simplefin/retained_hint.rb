require "time"

# Retains the volatile legacy classifier hint once, without extending its expiry.
# The enclosing typed archive/checksum supplies immutable source provenance.
class Provider::AccountData::Simplefin::RetainedHint
  FORMAT = "simplefin-retained-liability-hint/v1".freeze
  KEY = "simplefin_liability_hint".freeze
  MAX_BYTES = 4_096
  MAX_ACCOUNTS = 1_000

  def self.capture(legacy_id:)
    unless ApplicationRecord.connection.open_transactions.zero?
      raise Provider::AccountData::MigrationCopier::Conflict, "Capture the legacy cache outside database transactions"
    end
    raw = Rails.cache.read(cache_key(legacy_id))
    document = { "format" => FORMAT, "cache_key" => cache_key(legacy_id), "captured_at" => Time.current,
      "availability" => raw.nil? ? "absent" : "present", "raw_hint" => raw }
    validate!(document, legacy_id: legacy_id)
    Provider::AccountData::MigrationManifest.copy_value(document)
  end

  def self.validate!(document, legacy_id:)
    unless document.is_a?(Hash) && document.keys.sort == %w[availability cache_key captured_at format raw_hint] &&
        document["format"] == FORMAT && document["cache_key"] == cache_key(legacy_id) &&
        (document["captured_at"].is_a?(Time) || document["captured_at"].is_a?(ActiveSupport::TimeWithZone)) &&
        document["availability"] == (document["raw_hint"].nil? ? "absent" : "present")
      raise Provider::AccountData::MigrationCopier::Conflict, "SimpleFIN archive lacks its original classifier hint capture"
    end
    normalize(document["raw_hint"])
    if Provider::AccountData::MigrationValue.dump(document).bytesize > MAX_BYTES
      raise Provider::AccountData::MigrationCopier::Conflict, "SimpleFIN classifier hint exceeds its retained bound"
    end
    document
  rescue ArgumentError, TypeError
    raise Provider::AccountData::MigrationCopier::Conflict, "SimpleFIN classifier hint requires explicit reconciliation", cause: nil
  end

  def self.read(connection:, external:)
    reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "simplefin")
    reader.item_descriptor
    row = reader.account(external)
    return unless row
    unless external.identity_namespace == "connection" && row.attributes.fetch("account_id").to_s == external.external_id
      raise Provider::AccountData::StaleWriter, "Retained SimpleFIN classifier belongs to another source account"
    end
    Provider::AccountData::MigrationCopier.verify_account_binding!(archive: row.archive,
      link: external.account_provider, financial: external.current_account)
    document = row.archive.fetch("auxiliary_inputs").fetch(KEY)
    validate!(document, legacy_id: row.context.fetch("legacy_id"))
    normalize(document.fetch("raw_hint"))
  rescue Provider::AccountData::MigrationCopier::Conflict, KeyError, TypeError
    raise Provider::AccountData::StaleWriter, "Retained SimpleFIN classifier input is missing or changed", cause: nil
  end

  # Recheck source provenance without reading either cache values or archive bytes.
  # RuntimeInputs separately pins the current linked financial account identity.
  def self.live_input(connection:)
    reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "simplefin")
    accounts = connection.external_accounts.where(family_id: connection.family_id).includes(:account_provider).order(:id).limit(MAX_ACCOUNTS + 1).to_a
    raise Provider::AccountData::StaleWriter, "SimpleFIN retained inventory exceeds its bound" if accounts.size > MAX_ACCOUNTS
    descriptors = accounts.select { |external| external.account_provider }.to_h do |external|
      [ external.id, reader.account_descriptor(external) ]
    end
    { "item" => reader.item_descriptor, "accounts" => descriptors }
  end

  def self.cache_key(legacy_id)
    "simplefin:sfa:#{legacy_id}:liability_sign_hint"
  end

  def self.normalize(raw)
    return if raw.nil?
    unless raw.is_a?(Hash) && raw.size == 2 && raw.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
        raw.keys.map(&:to_s).sort == %w[expires_at value]
      raise Provider::AccountData::MigrationCopier::Conflict, "Invalid retained SimpleFIN classifier hint"
    end
    value = raw.with_indifferent_access
    unless (value[:value].is_a?(String) || value[:value].is_a?(Symbol)) && %w[credit debt].include?(value[:value].to_s)
      raise Provider::AccountData::MigrationCopier::Conflict, "Invalid retained SimpleFIN classifier value"
    end
    expiry = value.fetch(:expires_at)
    text = expiry.respond_to?(:iso8601) ? expiry.iso8601(9) : expiry
    unless text.is_a?(String) && text.bytesize <= 64 && text.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      raise Provider::AccountData::MigrationCopier::Conflict, "Invalid retained SimpleFIN classifier expiry"
    end
    expires_at = Time.iso8601(text).getutc.iso8601(9)
    { "value" => value.fetch(:value).to_s, "expires_at" => expires_at }
  rescue KeyError, TypeError, ArgumentError
    raise Provider::AccountData::MigrationCopier::Conflict, "Invalid retained SimpleFIN classifier hint", cause: nil
  end
  private_class_method :normalize
end
