module IbkrAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.delete(",").strip : value.to_s
      return nil if normalized.blank? || normalized == "-"

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when Date
        value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.to_date
      else
        normalized = value.to_s.tr(";", " ")
        Time.zone.parse(normalized)&.to_date || Date.parse(normalized)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def parse_datetime(value)
      return nil if value.blank?

      case value
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.in_time_zone
      when Date
        value.in_time_zone
      else
        Time.zone.parse(value.to_s.tr(";", " "))
      end
    rescue ArgumentError, TypeError
      nil
    end

    def resolve_security(row)
      data = row.with_indifferent_access
      ticker = data[:symbol].to_s.strip.upcase
      return nil if ticker.blank?

      Security.find_by(ticker: ticker) || create_security_from_row(ticker)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: ticker)
    end

    def trade_date_for(row)
      parse_date(row.with_indifferent_access[:trade_date]) || Date.current
    end

    def extract_currency(row, fallback: nil)
      value = row.with_indifferent_access[:currency]
      value.present? ? value.to_s.upcase : fallback
    end

    def create_security_from_row(ticker)
      Security.create!(ticker: ticker, name: ticker)
    end
end
