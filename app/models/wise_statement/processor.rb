# frozen_string_literal: true

class WiseStatement::Processor
  def initialize(statement, wise_account:)
    @statement = statement.with_indifferent_access
    @wise_account = wise_account
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseStatement::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    result = import_main_transaction

    if fee.positive?
      begin
        import_fee_transaction
      rescue => e
        Rails.logger.warn "WiseStatement::Processor - Fee transaction failed for statement #{safe_id}: #{e.message}"
      end
    end

    result
  rescue ArgumentError => e
    Rails.logger.error "WiseStatement::Processor - Validation error for statement #{safe_id}: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WiseStatement::Processor - Error for statement #{safe_id}: #{e.class}: #{e.message}"
    raise
  end

  private

    attr_reader :statement, :wise_account

    def account
      @account ||= wise_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def import_main_transaction
      import_adapter.import_transaction(
        external_id: "wise_statement_#{transaction_id}",
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "wise",
        extra: extra
      )
    end

    # The statement amount excludes fees, so the fee is imported as its own
    # entry (mirroring WiseEntry::Processor) to preserve the balance impact.
    def import_fee_transaction
      import_adapter.import_transaction(
        external_id: "wise_statement_#{transaction_id}_fee",
        amount: fee,
        currency: currency,
        date: date,
        name: I18n.t("wise_items.entries.fee_name"),
        source: "wise",
        extra: { wise: { statement_id: transaction_id, type: "FEE", fee: fee } }
      )
    end

    def transaction_id
      statement[:referenceNumber].presence || statement[:id].presence || digest
    end

    def safe_id
      statement[:referenceNumber].presence || statement[:id].presence || "unknown"
    end

    # Wise statements use a signed amount: credits are positive and debits are
    # negative. Sure uses the opposite sign convention for imported entries.
    # The statement amount is the full balance impact and includes fees, so the
    # reported totalFees are excluded to match the transfer importer's net amount.
    def amount
      signed = statement.dig(:amount, :value).to_d
      net = signed.abs - fee
      net = 0 if net.negative?

      signed.negative? ? net : -net
    end

    def currency
      statement.dig(:amount, :currency).presence || wise_account.currency
    end

    def date
      raw = statement[:date].presence
      raise ArgumentError, "Wise statement missing date" unless raw

      Time.parse(raw.to_s).in_time_zone(account.family.timezone).to_date
    rescue ArgumentError
      raise
    rescue => e
      raise ArgumentError, "Unable to parse Wise statement date #{raw.inspect}: #{e.message}"
    end

    def name
      details = statement[:details]
      base = details[:description].presence if details.is_a?(Hash) && details[:description].present?
      base ||= details[:reference].presence if details.is_a?(Hash) && details[:reference].present?
      base ||= statement[:referenceNumber].presence || I18n.t("wise_items.entries.default_name")

      payment_reference.present? ? "#{base} #{payment_reference}" : base
    end

    def extra
      {
        wise: {
          statement_id: transaction_id,
          statement_type: statement[:type],
          reference: statement[:referenceNumber],
          payment_reference: payment_reference,
          fee: fee.positive? ? fee : nil
        }.compact
      }
    end

    # Fee reported by Wise in totalFees. Only subtracted when denominated in the
    # transaction's currency so values are never mixed.
    def fee
      total_fees = statement[:totalFees]
      return 0 unless total_fees.is_a?(Hash)

      amount_currency = statement.dig(:amount, :currency)
      fee_currency = total_fees[:currency].presence
      return 0 if amount_currency.present? && fee_currency.present? && amount_currency != fee_currency

      total_fees[:value].to_d
    end

    def payment_reference
      statement.dig(:details, :paymentReference).presence
    end

    def digest
      Digest::SHA256.hexdigest(statement.to_json)[0, 24]
    end
end
