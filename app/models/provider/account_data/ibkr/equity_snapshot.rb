class Provider::AccountData::Ibkr::EquitySnapshot
  FORMAT = "ibkr_equity/v1"
  attr_reader :data

  def self.load(payload)
    raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == %w[data format] && payload["format"] == FORMAT
    new(**Provider::AccountData::MigrationValue.decode(payload.fetch("data")).symbolize_keys)
  end

  def initialize(external_id:, currency:, equity_rows:, statement_sha256:, observed_on:, imported_current_balance:, source_artifact: nil)
    raise ArgumentError unless external_id.is_a?(String) && external_id.present? && currency.is_a?(String) && currency.match?(/\A[A-Z]{3}\z/)
    raise ArgumentError unless statement_sha256.is_a?(String) && statement_sha256.match?(/\A[0-9a-f]{64}\z/) && observed_on.instance_of?(Date)
    raise ArgumentError unless equity_rows.is_a?(Array) && equity_rows.size <= 100_000
    raise ArgumentError unless imported_current_balance.is_a?(BigDecimal) && imported_current_balance.finite?
    if source_artifact
      unless source_artifact.is_a?(Hash) && source_artifact.keys.sort == %w[account_provider_id account_provider_revision inventory_batch_id inventory_payload_sha256 provider_sync_id] &&
          %w[account_provider_id inventory_batch_id provider_sync_id].all? { |key| source_artifact[key].is_a?(String) && source_artifact[key].present? } &&
          source_artifact["account_provider_revision"].is_a?(Integer) && source_artifact["account_provider_revision"] >= 0 &&
          source_artifact["inventory_payload_sha256"].is_a?(String) && source_artifact["inventory_payload_sha256"].match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError
      end
    end
    @data = Provider::AccountData::MigrationManifest.copy_value(
      "external_id" => external_id, "currency" => currency, "equity_rows" => equity_rows, "statement_sha256" => statement_sha256,
      "observed_on" => observed_on, "imported_current_balance" => imported_current_balance, "source_artifact" => source_artifact)
    freeze
  end

  def [](key)
    data.fetch(key.to_s)
  end

  def payload
    { "format" => FORMAT, "data" => Provider::AccountData::MigrationValue.encode(data) }
  end

  def inspect
    "#<#{self.class.name} rows=#{self[:equity_rows].size}>"
  end
end
