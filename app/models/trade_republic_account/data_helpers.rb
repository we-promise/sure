module TradeRepublicAccount::DataHelpers
  extend ActiveSupport::Concern

  # Timeline event categories Trade Republic emits. Only explicitly mapped
  # categories are imported; anything unknown is skipped and recorded rather
  # than guessed into a transaction.
  CATEGORY_DEPOSIT = "PAYMENT_RECEIVED"
  CATEGORY_WITHDRAWAL = "POC_CREATED"
  CATEGORY_INTEREST = "INTEREST_PAYOUT_CREATED"
  CATEGORY_DIVIDEND = "DIVIDEND"
  KNOWN_ACTIVITY_CATEGORIES = [ CATEGORY_DEPOSIT, CATEGORY_WITHDRAWAL, CATEGORY_INTEREST, CATEGORY_DIVIDEND, "orderExecution" ].freeze

  TRANSFER_EVENT_TYPES = %w[
    PAYMENT_INBOUND PAYMENT_OUTBOUND INCOMING_TRANSFER OUTGOING_TRANSFER
    INCOMING_TRANSFER_DELEGATION OUTGOING_TRANSFER_DELEGATION
  ].freeze

  private

    def parse_decimal(value)
      return nil if value.nil?

      normalized = value.is_a?(String) ? value.strip : value.to_s
      return nil if normalized.blank?

      BigDecimal(normalized)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      return nil if value.blank?

      case value
      when DateTime, Time, ActiveSupport::TimeWithZone
        value.to_date
      when Date
        value
      else
        Time.zone.parse(value.to_s)&.to_date || Date.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # Resolve (or create) a Security from a Trade Republic position. The ISIN
    # is the stable provider identifier; ticker matching falls back to it
    # because the securities table has no ISIN column.
    def resolve_security(isin, name)
      return nil if isin.blank?

      Security.find_by(ticker: isin) ||
        Security.create!(ticker: isin, name: name.presence || isin)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: isin)
    end
end
