# These are trusted application bindings, never names supplied by provider data.
# RuntimeContext reads both methods under its settings lock and keys the complete
# live context. The feeder sees only options, including a keyed secret revision.
class Provider::AccountData::OnchainWallet::FxConfiguration
  PURPOSE = "onchain-fx-credentials/v1".freeze

  def self.credentials
    provider = ENV["EXCHANGE_RATE_PROVIDER"].presence || setting("exchange_rate_provider")
    values = { "provider" => provider.to_s }
    if provider == "twelve_data"
      values["api_key"] = ENV["TWELVE_DATA_API_KEY"].presence || Setting.send(:decrypt_setting, setting("twelve_data_api_key"))
    end
    values
  end

  def self.options
    values = credentials
    provider = values.fetch("provider")
    endpoint = case provider
    when "twelve_data" then ENV["TWELVE_DATA_URL"].presence || "https://api.twelvedata.com"
    when "frankfurter" then ENV["FRANKFURTER_URL"].presence || "https://api.frankfurter.dev/v2"
    when "moex_public" then ENV["MOEX_ISS_URL"].presence || "https://iss.moex.com/iss"
    when "yahoo_finance" then ENV["YAHOO_FINANCE_URL"].presence || "https://query1.finance.yahoo.com"
    end
    interval = if provider == "twelve_data"
      configured = ENV.fetch("TWELVE_DATA_MIN_REQUEST_INTERVAL", Provider::TwelveData::MIN_REQUEST_INTERVAL).to_f
      credits = ENV.fetch("TWELVE_DATA_MAX_REQUESTS_PER_MINUTE", "7").to_i.clamp(1, 1_000)
      [ configured.finite? ? configured.clamp(1, 60) : 1, 60.0 / credits ].max
    elsif provider == "yahoo_finance"
      configured = ENV.fetch("YAHOO_FINANCE_MIN_REQUEST_INTERVAL", Provider::YahooFinance::MIN_REQUEST_INTERVAL).to_f
      configured.finite? ? configured.clamp(0.5, 60) : 0.5
    else
      0.4
    end
    options = { "version" => 1, "provider" => provider, "endpoint" => endpoint,
      "credential_fingerprint" => fingerprint(values), "min_interval_seconds" => interval.to_s }
    options["history_policy"] = Provider::AccountData::OnchainWallet::MoexFxReader.policy if provider == "moex_public"
    if provider == "yahoo_finance"
      options["user_agent"] = Provider::YahooFinance::USER_AGENTS.first
      options["acquisition_policy"] = Provider::AccountData::OnchainWallet::FxAcquisition.yahoo_policy
    end
    options
  end

  def self.fingerprint(values)
    Provider::AccountData::RuntimeInputs.fingerprint(values, purpose: PURPOSE)
  end

  def self.setting(key)
    field = Setting.defined_fields.find { |definition| definition.key == key } || raise(ArgumentError)
    Setting.uncached do
      stored = Setting.unscoped.find_by(var: key)&.value
      field.deserialize(field.readonly || stored.nil? ? field.default_value : stored)
    end
  end
  private_class_method :setting
end
