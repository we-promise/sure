# frozen_string_literal: true

class GocardlessAccount::Transactions::Processor
  include GocardlessAccount::DataHelpers

  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    unless gocardless_account.raw_transactions_payload.present?
      Rails.logger.info "GocardlessAccount::Transactions::Processor - No transactions in raw_transactions_payload for gocardless_account #{gocardless_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = gocardless_account.raw_transactions_payload.count
    Rails.logger.info "GocardlessAccount::Transactions::Processor - Processing #{total_count} transactions for gocardless_account #{gocardless_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    gocardless_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          # Transaction was skipped (e.g., no linked account or blank external_id)
          failed_count += 1
          transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
          errors << { index: index, transaction_id: transaction_id, error: "Skipped" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "GocardlessAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "GocardlessAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "GocardlessAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "GocardlessAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def account
      @gocardless_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      external_id = external_id_for(data)
      return nil if external_id.blank?

      # Parse transaction attributes
      amount = parse_transaction_amount(data)
      return nil if amount.nil?

      # bookingDate is when the bank settled it and is what the statement shows.
      # valueDate is the interest date and can differ by days. Prefer booking, fall back
      # to value, then the datetime variant that some banks send instead.
      date = parse_date(
        data[:bookingDate] || data[:valueDate] || data[:bookingDateTime] || data[:valueDateTime],
        family: account&.family
      )
      return nil if date.nil?

      name = transaction_name(data)
      currency = data.dig(:transactionAmount, :currency).presence || account.currency

      # Build provider-specific metadata for transaction.extra
      extra = build_extra_metadata(data)

      Rails.logger.info "GocardlessAccount::Transactions::Processor - Importing transaction: id=#{external_id} amount=#{amount} date=#{date}"

      # Use ProviderImportAdapter for proper deduplication via external_id + source
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "gocardless",
        extra: extra,
        replace_extra_namespaces: [ "gocardless" ]
      )
    end

    # GoCardless follows the bank's own sign convention: a debit (money leaving the
    # account) is NEGATIVE and a credit is POSITIVE. Sure is the exact inverse, so every
    # amount is negated here. Getting this backwards silently turns every expense into
    # income and still "works", so it is the single most important line in this file.
    def parse_transaction_amount(data)
      amount = parse_decimal(data.dig(:transactionAmount, :amount))
      return nil if amount.nil?

      -amount
    end

    # transactionId is the bank's stable identifier and is what dedup keys on. Pending
    # entries frequently arrive WITHOUT one, so a deterministic surrogate is derived from
    # the fields that do exist.
    #
    # Caveat worth knowing: when such a pending entry later posts, it arrives with a real
    # transactionId and no longer matches the surrogate, so it can appear twice until the
    # pending copy ages out. Banks that do send transactionId on pending entries are
    # unaffected. Preferred over dropping pending entries entirely, which would leave
    # recent spending invisible.
    def external_id_for(data)
      id = data[:transactionId].presence || data[:internalTransactionId].presence
      return id.to_s if id.present?

      fingerprint = [
        data[:bookingDate] || data[:valueDate],
        data.dig(:transactionAmount, :amount),
        transaction_name(data)
      ].join("|")

      "pending:#{Digest::SHA256.hexdigest(fingerprint)[0..31]}"
    end

    # Banks scatter the human-readable description across several optional fields, and
    # which one is populated varies by institution, so fall through them in order of
    # usefulness rather than trusting any single one.
    def transaction_name(data)
      unstructured = data[:remittanceInformationUnstructured].presence ||
                     Array(data[:remittanceInformationUnstructuredArray]).join(" ").presence

      counterparty = data[:creditorName].presence || data[:debtorName].presence

      (unstructured || counterparty || data[:additionalInformation].presence || "Transaction").to_s.squish
    end

    def build_extra_metadata(data)
      {
        "gocardless" => {
          "id" => data[:transactionId],
          "internal_id" => data[:internalTransactionId],
          "pending" => data[:pending],
          "merchant" => data[:creditorName] || data[:debtorName],
          "category" => data[:merchantCategoryCode],
          "bank_transaction_code" => data[:proprietaryBankTransactionCode]
        }.compact
      }
    end
end
