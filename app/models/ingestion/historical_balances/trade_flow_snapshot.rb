# FX I/O and the all-account trade projection happen before financial locks.
# Opening-anchor repair and balance materialization may change other inputs;
# any change to the captured trade inputs rejects the entire calculation.
class Ingestion::HistoricalBalances::TradeFlowSnapshot
  FORMAT = "account_trade_flows/v1".freeze
  attr_reader :data

  def self.capture(account:, rate_resolver: Provider::AccountData::ExchangeRateResolver.new)
    inputs = Ingestion::HistoricalBalances::Inputs.capture(account.reload)
    result = Ingestion::HistoricalBalances::TradeFlows.new(inputs: inputs, currency: account.currency, rate_resolver: rate_resolver).capture
    new("account_id" => account.id, "currency" => account.currency, "inputs_sha256" => fingerprint(inputs), "result" => result)
  end

  def self.load(payload)
    raise ArgumentError unless payload.is_a?(Hash) && payload.keys.sort == %w[data format] && payload["format"] == FORMAT
    new(Provider::AccountData::MigrationValue.decode(payload.fetch("data")))
  end

  def self.fingerprint(inputs)
    entries = inputs.fetch("entries").select { |entry| entry.fetch("entryable_type") == "Trade" }
    Ingestion::HistoricalBalances.fingerprint("account_id" => inputs.fetch("account").fetch("id"),
      "currency" => inputs.fetch("account").fetch("currency"), "entries" => entries, "trades" => inputs.fetch("trades"))
  end

  def initialize(data)
    raise ArgumentError unless data.is_a?(Hash) && data.keys.sort == %w[account_id currency inputs_sha256 result]
    raise ArgumentError unless data["account_id"].is_a?(String) && data["currency"].is_a?(String) && data["inputs_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
    result = data.fetch("result")
    raise ArgumentError unless result.is_a?(Hash) && result.keys.sort == %i[evidence failed_dates flows]
    raise ArgumentError unless result[:flows].is_a?(Hash) && result[:flows].all? { |date, amount| date.instance_of?(Date) && amount.is_a?(BigDecimal) && amount.finite? }
    raise ArgumentError unless result[:failed_dates].is_a?(Array) && result[:failed_dates].all? { |date| date.instance_of?(Date) } && result[:evidence].is_a?(Array)
    @data = Provider::AccountData::MigrationManifest.copy_value(data)
    freeze
  end

  def payload
    { "format" => FORMAT, "data" => Provider::AccountData::MigrationValue.encode(data) }
  end

  def resolve(inputs:, currency:)
    unless currency == data.fetch("currency") && self.class.fingerprint(inputs) == data.fetch("inputs_sha256")
      raise Provider::AccountData::StaleWriter, "Account trades changed after FX preparation"
    end
    data.fetch("result")
  end
end
