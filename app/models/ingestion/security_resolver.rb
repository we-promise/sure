# Security lookup may call market-data APIs. Run it after capture and before the
# connection/account write transaction; the writer rechecks source authority.
class Ingestion::SecurityResolver
  def initialize(account: nil)
    @account = account
  end

  def resolve(page)
    page.records.each_with_object({}) do |record, resolved|
      next unless record[:security]
      values = record[:security].with_indifferent_access
      key = [ record.kind, record[:external_id] ]
      if values[:lookup] == "account_cash"
        unless @account && values[:currency].is_a?(String) && values[:currency] == record[:currency]
          raise Provider::AccountData::InvalidResponse, "Cash security needs a linked account and matching currency"
        end
        resolved[key] = Security.cash_for(@account, currency: values[:currency])
        next
      end
      if values[:lookup] == "onchain_asset"
        resolved[key] = onchain_security(values)
        next
      end
      ticker = values[:ticker]
      unless ticker.is_a?(String) && ticker.present?
        raise Provider::AccountData::UnsupportedCapability, "A supported security identifier is required"
      end
      resolved[key] = if values[:lookup] == "ticker_only"
        ticker_only_security(values)
      elsif values[:offline] == true
        offline_security(values)
      else
        begin
          Security::Resolver.new(ticker, exchange_operating_mic: values[:exchange_operating_mic],
            country_code: values[:country_code]).resolve
        rescue StandardError
          raise unless values[:fallback_offline] == true
          fallback = values.merge(exchange_operating_mic: values[:fallback_exchange_operating_mic] || values[:exchange_operating_mic])
          offline_security(fallback, ticker_only: values[:fallback_lookup] == "ticker_only")
        end
      end
      raise Provider::AccountData::InvalidResponse, "Security could not be resolved" unless resolved[key]
    end
  end

  private
    def onchain_security(values)
      unless (values.keys.map(&:to_s) - %w[lookup symbol ticker name]).empty? && values[:symbol].is_a?(String) &&
          values[:name].is_a?(String) && values[:name].present?
        raise Provider::AccountData::InvalidResponse, "Invalid on-chain security descriptor"
      end
      canonical = Onchain::AssetSymbol.canonical(values[:symbol])
      unless Onchain::SecurityResolver::SYMBOL_PATTERN.match?(canonical) && values[:ticker] == "CRYPTO:#{canonical}"
        raise Provider::AccountData::InvalidResponse, "On-chain asset symbol and ticker do not agree"
      end
      security = Onchain::SecurityResolver.resolve(symbol: values[:symbol], name: values[:name])
      raise Provider::AccountData::InvalidResponse, "On-chain asset could not be resolved" unless security
      security
    end

    def ticker_only_security(values)
      ticker = values.fetch(:ticker).strip.upcase
      security = Security.find_by(ticker: ticker)
      if security
        if values[:repair_malformed_name] == true && security.name&.start_with?("{") && values[:name].is_a?(String) && values[:name].present?
          security.update!(name: values[:name])
        end
        return security
      end
      # exchange_mic and exchange_operating_mic are distinct legacy columns.
      # Preserve their meanings rather than migrating identity during lookup.
      Security.create!(ticker: ticker, name: values[:name], exchange_mic: values[:exchange_mic],
        exchange_operating_mic: values[:exchange_operating_mic], country_code: values[:country_code])
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def offline_security(values, ticker_only: false)
      identity = { ticker: values.fetch(:ticker).strip.upcase }
      identity[:exchange_operating_mic] = values[:exchange_operating_mic] unless ticker_only
      Security.find_or_initialize_by(identity).tap do |security|
        # Do not downgrade an existing market-data security or overwrite its name.
        if security.new_record?
          security.offline = true
          security.exchange_operating_mic = values[:exchange_operating_mic]
        end
        security.name = values[:name] if security.name.blank? && values[:name].present?
        security.save! if security.changed?
      end
    end
end
