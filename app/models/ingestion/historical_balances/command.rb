# The rows and all financial/FX inputs are captured together. Applying this value
# never reads a market-data API or resolves a provider-controlled class name.
class Ingestion::HistoricalBalances::Command
  attr_reader :data

  def self.load(payload)
    unless payload.is_a?(Hash) && payload.keys.sort == %w[data format] && payload["format"] == Ingestion::HistoricalBalances::FORMAT
      raise ArgumentError, "Unknown historical balance command"
    end
    new(Provider::AccountData::MigrationValue.decode(payload.fetch("data")))
  end

  def initialize(data)
    validate!(data)
    @data = Provider::AccountData::MigrationManifest.copy_value(data)
    freeze
  end

  def payload
    { "format" => Ingestion::HistoricalBalances::FORMAT, "data" => Provider::AccountData::MigrationValue.encode(data) }
  end

  def [](key)
    data.fetch(key.to_s)
  end

  def stream
    self[:phase] == "opening_anchor" ? "opening_anchor_repairs" : "historical_balances"
  end

  def inspect
    "#<#{self.class.name} phase=#{self[:phase]} rows=#{self[:rows].size}>"
  end

  private
    def validate!(value)
      required = %w[account_id family_id external_account_id provider_connection_id account_provider_id source_batch_id source_policy_version
        account_provider_revision balance_policy_version writer_epoch phase capture_revision observed_on source_sha256 inputs inputs_sha256 rows opening_anchor anchor_policy_version fx_evidence failed_fx_dates protected_dates]
      raise ArgumentError unless value.is_a?(Hash) && value.keys.sort == required.sort
      %w[account_id family_id external_account_id provider_connection_id account_provider_id source_batch_id source_policy_version].each do |key|
        raise ArgumentError unless value[key].is_a?(String) && value[key].present?
      end
      raise ArgumentError unless %w[opening_anchor equity_history].include?(value["phase"])
      raise ArgumentError unless value["capture_revision"].is_a?(String) && value["capture_revision"].match?(/\A[A-Za-z0-9-]{1,64}\z/)
      raise ArgumentError unless value["writer_epoch"].is_a?(Integer) && value["writer_epoch"] >= 0 && value["observed_on"].instance_of?(Date)
      raise ArgumentError unless value["account_provider_revision"].is_a?(Integer) && value["account_provider_revision"] >= 0
      raise ArgumentError unless value["balance_policy_version"].nil? || (value["balance_policy_version"].is_a?(String) && value["balance_policy_version"].present?)
      %w[source_sha256 inputs_sha256].each { |key| raise ArgumentError unless value[key].is_a?(String) && value[key].match?(/\A[0-9a-f]{64}\z/) }
      inputs = value["inputs"]
      raise ArgumentError unless inputs.is_a?(Hash) && inputs.keys.sort == %w[account balances entries trades valuations]
      raise ArgumentError unless inputs["account"].is_a?(Hash) && inputs["account"]["id"] == value["account_id"] && inputs["account"]["family_id"] == value["family_id"]
      raise ArgumentError unless %w[entries trades valuations balances].all? { |key| inputs[key].is_a?(Array) }
      raise ArgumentError unless Ingestion::HistoricalBalances.fingerprint(inputs) == value["inputs_sha256"]
      raise ArgumentError unless value["rows"].is_a?(Array) && value["rows"].size <= 36_601
      value["rows"].each do |row|
        raise ArgumentError unless row.is_a?(Hash) && row.keys.sort == Ingestion::HistoricalBalances::COLUMNS.sort
        raise ArgumentError unless row[:date].instance_of?(Date) && row[:date] <= value["observed_on"] && row[:currency] == inputs["account"]["currency"] && row[:flows_factor] == 1
        raise ArgumentError unless Ingestion::HistoricalBalances::MONEY_COLUMNS.all? { |key| row[key].is_a?(BigDecimal) && row[key].finite? }
      end
      dates = value["rows"].map { |row| row.fetch(:date) }
      raise ArgumentError unless dates.uniq == dates && dates.sort == dates
      %w[failed_fx_dates protected_dates].each do |key|
        raise ArgumentError unless value[key].is_a?(Array) && value[key].all? { |date| date.instance_of?(Date) }
      end
      raise ArgumentError unless (dates & (value["failed_fx_dates"] + value["protected_dates"])).empty?
      raise ArgumentError unless value["fx_evidence"].is_a?(Array)
      anchor = value["opening_anchor"]
      if anchor
        raise ArgumentError unless value["anchor_policy_version"].is_a?(String) && value["anchor_policy_version"].present?
        raise ArgumentError unless value["anchor_policy_version"] == value["balance_policy_version"]
        raise ArgumentError unless value["phase"] == "opening_anchor" && anchor.is_a?(Hash) && anchor.keys.sort == %w[amount currency date entry_id replacement]
        raise ArgumentError unless anchor["entry_id"].is_a?(String) && anchor["date"].instance_of?(Date) && anchor["currency"] == inputs["account"]["currency"] &&
          anchor["amount"].is_a?(BigDecimal) && anchor["amount"].finite? && anchor["replacement"] == BigDecimal("0")
      elsif value["anchor_policy_version"]
        raise ArgumentError
      end
      raise ArgumentError unless value["phase"] == "equity_history" || value["rows"].empty?
    end
end
