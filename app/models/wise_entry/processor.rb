# frozen_string_literal: true

class WiseEntry::Processor
  # Statuses Wise uses for outgoing transfers (money leaves the Wise balance).
  OUTGOING_STATUSES = %w[
    processing funds_converted outgoing_payment_sent
    bounced_back funds_refunded
  ].freeze

  # Statuses Wise uses for incoming transfers (money arrives in the Wise balance).
  INCOMING_STATUSES = %w[
    incoming_payment_waiting incoming_payment_received
    funds_credited credited
  ].freeze

  def initialize(wise_transaction, wise_account:)
    @wise_transaction = wise_transaction
    @wise_account = wise_account
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseEntry::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    result = import_main_transaction

    if fee > 0
      begin
        import_fee_transaction
      rescue StandardError => e
        Rails.logger.warn "WiseEntry::Processor - Fee transaction failed for transfer #{safe_id}: #{e.message}"
      end
    end

    result
  rescue ArgumentError => e
    Rails.logger.error "WiseEntry::Processor - Validation error for transfer #{safe_id}: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WiseEntry::Processor - Unexpected error for transfer #{safe_id}: #{e.class} - #{e.message}"
    raise
  end

  private

    attr_reader :wise_transaction, :wise_account

    def data
      @data ||= wise_transaction.with_indifferent_access
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= wise_account.current_account
    end

    def import_main_transaction
      import_adapter.import_transaction(
        external_id: "wise_transfer_#{transfer_id}",
        amount: main_amount,
        currency: source_currency,
        date: date,
        name: name,
        source: "wise",
        extra: extra
      )
    end

    def import_fee_transaction
      import_adapter.import_transaction(
        external_id: "wise_fee_#{transfer_id}",
        amount: fee,
        currency: source_currency,
        date: date,
        name: I18n.t("wise_items.entries.fee_name"),
        source: "wise",
        extra: { wise: { transfer_id: transfer_id, type: "FEE" } }
      )
    end

    def transfer_id
      data[:id].presence.tap { |id| raise ArgumentError, "Wise transfer missing id" unless id }
    end

    def safe_id
      data[:id].presence || "unknown"
    end

    def name
      ref = data.dig(:details, :reference).presence || data[:reference].presence
      ref.present? ? ref : I18n.t("wise_items.entries.default_name")
    end

    # Expenses (outgoing) → positive amount in Sure convention.
    # Incomes (incoming)  → negative amount in Sure convention.
    # Incoming cross-currency transfers use targetValue (what actually arrived) not sourceValue.
    def main_amount
      if outgoing?
        data[:sourceValue].to_d.abs
      else
        -(data[:targetValue].to_d.abs)
      end
    end

    # Fee is the difference between what was debited and what the recipient received,
    # only applicable for same-currency transfers.
    def fee
      @fee ||= begin
        return 0 unless source_currency == target_currency

        diff = (data[:sourceValue].to_d - data[:targetValue].to_d).round(4)
        diff > 0 ? diff : 0
      end
    end

    def source_currency
      data[:sourceCurrency].presence || wise_account.currency
    end

    def target_currency
      data[:targetCurrency].presence || wise_account.currency
    end

    # An expense if targetAccount does NOT match our Wise recipientId
    # (i.e. money went TO an external account, not to us).
    # An income if targetAccount == recipientId (money arrived at our Wise account).
    # Falls back to status-based detection when no recipientId is stored.
    def outgoing?
      recipient_id = wise_account.raw_payload&.dig("recipient_id")

      if recipient_id.present?
        return data[:targetAccount].to_s != recipient_id.to_s
      end

      # Status-based fallback
      status = data[:status].to_s.downcase
      return false if INCOMING_STATUSES.any? { |s| status.include?(s) }
      return true  if OUTGOING_STATUSES.any? { |s| status.include?(s) }

      true
    end

    def date
      raw = data[:created].presence
      raise ArgumentError, "Wise transfer missing created date" unless raw

      case raw
      when Date then raw
      when String
        if raw.include?("T") || raw.include?(":")
          Time.parse(raw).in_time_zone(account&.family&.timezone).to_date
        else
          Date.parse(raw)
        end
      when Time, DateTime
        raw.in_time_zone(account&.family&.timezone).to_date
      else raise ArgumentError, "Invalid date format: #{raw.inspect}"
      end
    rescue ArgumentError
      raise
    rescue => e
      raise ArgumentError, "Unable to parse date #{raw.inspect}: #{e.message}"
    end

    def extra
      {
        wise: {
          transfer_id: transfer_id,
          status: data[:status],
          direction: outgoing? ? "outgoing" : "incoming",
          source_currency: source_currency,
          source_value: data[:sourceValue],
          target_currency: target_currency,
          target_value: data[:targetValue],
          rate: data[:rate],
          fee: fee > 0 ? fee : nil,
          reference: data.dig(:details, :reference).presence || data[:reference]
        }.compact
      }
    end
end
