require "digest"

# One export belongs to one provider sync, even when a later request would return
# byte-identical XML. Scope is captured alongside the original response.
class Provider::AccountData::Ibkr::Export
  VERSION = 1
  SCOPE_KEYS = %w[family_id provider_connection_id sync_id observed_at observed_on timezone].freeze
  REFERENCE_KEYS = %w[version scope statement_sha256].freeze
  attr_reader :scope, :statement

  def self.scope(family_id:, provider_connection_id:, sync_id:, observed_at:, timezone:)
    value = { "family_id" => family_id, "provider_connection_id" => provider_connection_id, "sync_id" => sync_id,
      "observed_at" => observed_at.to_time.utc.iso8601(9), "observed_on" => observed_at.in_time_zone(timezone).to_date.iso8601, "timezone" => timezone }
    validate_scope!(value)
    Provider::AccountData::MigrationManifest.copy_value(value)
  end

  def self.validate_scope!(value)
    raise ArgumentError unless value.is_a?(Hash) && value.keys.sort == SCOPE_KEYS.sort
    %w[family_id provider_connection_id sync_id].each do |key|
      raise ArgumentError unless value[key].is_a?(String) && value[key].match?(/\A[A-Za-z0-9-]{1,64}\z/)
    end
    raise ArgumentError unless value["timezone"].is_a?(String) && ActiveSupport::TimeZone[value["timezone"]]
    raise ArgumentError unless value["observed_at"].is_a?(String) && value["observed_on"].is_a?(String)
    observed = Time.iso8601(value.fetch("observed_at"))
    raise ArgumentError unless observed.utc.iso8601(9) == value["observed_at"] && observed.in_time_zone(value["timezone"]).to_date.iso8601 == value["observed_on"]
    true
  end

  def self.validate_reference!(value, expected_scope:)
    unless value.is_a?(Hash) && value.except("response_xml").keys.sort == REFERENCE_KEYS.sort && value["version"] == VERSION &&
        value["statement_sha256"].is_a?(String) && value["statement_sha256"].match?(/\A[0-9a-f]{64}\z/)
      raise ArgumentError
    end
    validate_scope!(value["scope"])
    raise ArgumentError unless value["scope"] == expected_scope
    true
  end

  def self.load(value, expected_scope:)
    validate_reference!(value, expected_scope: expected_scope)
    export = new(xml: value.fetch("response_xml"), scope: expected_scope)
    raise ArgumentError unless export.statement.fingerprint == value.fetch("statement_sha256")
    export
  end

  def initialize(xml:, scope:)
    self.class.validate_scope!(scope)
    @scope = Provider::AccountData::MigrationManifest.copy_value(scope)
    @statement = Provider::AccountData::Ibkr::Statement.new(xml, observed_on: Date.iso8601(scope.fetch("observed_on")))
    freeze
  end

  def reference
    { "version" => VERSION, "scope" => scope, "statement_sha256" => statement.fingerprint }
  end

  def payload
    reference.merge("response_xml" => statement.xml)
  end

  def inspect
    "#<#{self.class.name} accounts=#{statement.accounts.size}>"
  end
end
