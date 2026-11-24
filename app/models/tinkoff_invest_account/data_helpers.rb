module TinkoffInvestAccount::DataHelpers
  extend ActiveSupport::Concern
  include CurrencyNormalizable

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_quotation(quotation)
      Provider::TinkoffInvest.quotation_to_decimal(quotation)
    end

    def parse_money(money_value, default_currency = "RUB")
      Provider::TinkoffInvest.money_to_decimal_and_currency(money_value, default_currency)
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when Date
        value
      when DateTime, Time, ActiveSupport::TimeWithZone
        value.to_date
      else
        Time.zone.parse(value.to_s)&.to_date || Date.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_instrument_type(raw_type)
      raw_type.to_s.downcase.delete_prefix("instrument_type_")
    end

    def resolve_security(ticker:, exchange_operating_mic: nil, country_code: nil, name: nil, logo_url: nil)
      normalized_ticker = ticker.to_s.strip.upcase
      return nil if normalized_ticker.blank?

      mic = Security.canonical_exchange_operating_mic(exchange_operating_mic)
      cc = country_code.to_s.strip.upcase.presence

      security = if mic.present?
        begin
          Security::Resolver.new(normalized_ticker, exchange_operating_mic: mic, country_code: cc).resolve
        rescue => e
          Rails.logger.warn("TinkoffInvestAccount: resolving #{normalized_ticker}|#{mic} failed (#{e.class}: #{e.message}); using offline security")
          nil
        end
      end

      security ||= offline_security(normalized_ticker, mic, country_code: cc)
      enrich_security_metadata(security, name: name, logo_url: logo_url, country_code: cc)
      security
    end

    def offline_security(ticker, mic, country_code: nil)
      Security.find_or_initialize_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic).tap do |security|
        if security.new_record?
          security.offline = true
          security.country_code = country_code if country_code.present?
        end
        security.save! if security.changed?
      end
    rescue ActiveRecord::RecordNotUnique
      Security.find_by_ticker_and_exchange(ticker: ticker, exchange_operating_mic: mic)
    end

    def enrich_security_metadata(security, name: nil, logo_url: nil, country_code: nil)
      return unless security

      updates = {}
      updates[:name] = name if name.present? && security.name.blank?
      updates[:logo_url] = logo_url if logo_url.present? && security.logo_url.blank?
      updates[:country_code] = country_code if country_code.present? && security.country_code.blank?
      security.update!(updates) if updates.any?
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("TinkoffInvestAccount: failed to enrich security #{security.id}: #{e.message}")
    end
end
