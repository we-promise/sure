# frozen_string_literal: true

class WiseStatement::Processor
  # A statement row's date is a UTC ISO-8601 timestamp; nil when it has
  # none or it does not parse.
  def self.posted_at(statement)
    raw = statement["date"]
    ActiveSupport::TimeZone["UTC"].parse(raw.to_s) if raw.present?
  rescue ArgumentError
    nil
  end

  # What a statement row's entries are keyed by (wise_statement_<id>). Wise
  # reuses a transfer's reference on its refund, so rows after the first
  # with a reference carry their own id ("wise_statement_id", see
  # WiseItem::StatementMigration). Sure's own marks stay out of the
  # fallback digest, as they change between syncs.
  def self.transaction_id(statement)
    statement["wise_statement_id"].presence || statement["referenceNumber"].presence || statement["id"].presence ||
      Digest::SHA256.hexdigest(statement.except(*WiseItem::StatementMigration::MARKER_KEYS).to_json)[0, 24]
  end

  def initialize(statement, wise_account:)
    @statement = statement.with_indifferent_access
    @wise_account = wise_account
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseStatement::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    if superseded?
      Rails.logger.debug "WiseStatement::Processor - Statement #{safe_id} is booked as #{statement[:wise_superseded_by]}, skipping"
      return :skipped
    end

    result = import_main_transaction

    if booked_fee.positive?
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

  # The external ids of the entries processing this statement row keeps on
  # its balance (see WiseAccount::Transactions::Processor's prune): none
  # for a conversion its activity books instead.
  def expected_external_ids
    return [] if superseded?

    ids = [ main_external_id ]
    ids << fee_external_id if booked_fee.positive?
    ids
  end

  # The entries a row booked before the balance had statements, which this
  # row takes over (WiseItem::StatementMigration): { old external id =>
  # this row's external id }, the fee only when this row books one.
  # WiseAccount::Transactions::Processor renames them before it books.
  def superseded_external_ids
    supersedes = statement[:wise_supersedes]
    return {} if superseded? || !supersedes.is_a?(Hash)

    ids = {}
    ids[supersedes[:main]] = main_external_id if supersedes[:main].present?
    ids[supersedes[:fee]] = fee_external_id if supersedes[:fee].present? && booked_fee.positive?
    ids
  end

  # The day the row books on; nil when it has no readable date.
  def booking_date
    date if account.present?
  rescue ArgumentError
    nil
  end

  private

    attr_reader :statement, :wise_account

    def account
      @account ||= wise_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Imports through the adapter; Wise's amount also reaches an entry a
    # person acted on (WiseItem::AmountCorrection).
    def import_entry(**attributes)
      entry = import_adapter.import_transaction(**attributes)
      WiseItem::AmountCorrection.apply(entry, amount: attributes[:amount], currency: attributes[:currency])
    end

    def import_main_transaction
      import_entry(
        external_id: main_external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "wise",
        extra: extra,
        # extra[:wise] is the full snapshot, so a flag Wise stops reporting clears.
        replace_extra_namespaces: [ "wise" ]
      )
    end

    # A debit's statement amount includes its fee, so the fee is imported as
    # its own entry (mirroring WiseEntry::Processor) to preserve the balance
    # impact.
    def import_fee_transaction
      import_entry(
        external_id: fee_external_id,
        amount: booked_fee,
        currency: currency,
        date: date,
        name: I18n.t("wise_items.entries.fee_name"),
        source: "wise",
        extra: { wise: { statement_id: transaction_id, type: "FEE", fee: booked_fee } },
        replace_extra_namespaces: [ "wise" ]
      )
    end

    # A conversion Wise's activity books on this balance (an INTERBALANCE
    # leg), so this row books nothing (WiseItem::StatementMigration).
    def superseded?
      statement[:wise_superseded_by].present?
    end

    def main_external_id
      "wise_statement_#{transaction_id}"
    end

    def fee_external_id
      "wise_statement_#{transaction_id}_fee"
    end

    def transaction_id
      @transaction_id ||= self.class.transaction_id(statement)
    end

    def safe_id
      statement[:referenceNumber].presence || statement[:id].presence || "unknown"
    end

    # Wise statements use a signed amount: credits are positive and debits are
    # negative. Sure uses the opposite sign convention for imported entries.
    # A debit's amount is its whole balance impact, so the fee (booked on its
    # own) is taken out to match the transfer importer's net amount. A
    # credit's amount is what reached the balance, already net of its fee,
    # which is only kept in extra.
    def amount
      signed = signed_amount
      return -signed unless signed.negative?

      net = signed.abs - booked_fee
      net.negative? ? 0.to_d : net
    end

    def signed_amount
      statement.dig(:amount, :value).to_d
    end

    def currency
      statement.dig(:amount, :currency).presence || wise_account.currency
    end

    def date
      raw = statement[:date].presence
      raise ArgumentError, "Wise statement missing date" unless raw

      posted_at = self.class.posted_at(statement)
      raise ArgumentError, "Unable to parse Wise statement date #{raw.inspect}" unless posted_at

      posted_at.in_time_zone(wise_account.wise_item.time_zone).to_date
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

    # Fee reported by Wise in totalFees. Only counted when denominated in the
    # transaction's currency so values are never mixed.
    def fee
      total_fees = statement[:totalFees]
      return 0.to_d unless total_fees.is_a?(Hash)

      amount_currency = statement.dig(:amount, :currency)
      fee_currency = total_fees[:currency].presence
      return 0.to_d if amount_currency.present? && fee_currency.present? && amount_currency != fee_currency

      total_fees[:value].to_d
    end

    # Only a debit books its fee as an entry of its own (see #amount).
    def booked_fee
      signed_amount.negative? ? fee : 0.to_d
    end

    def payment_reference
      statement.dig(:details, :paymentReference).presence
    end
end
