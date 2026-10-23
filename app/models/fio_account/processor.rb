# frozen_string_literal: true

class FioAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :fio_account

  def initialize(fio_account)
    @fio_account = fio_account
  end

  # Sync the linked account's balance and process its movements. No-op when the Fio
  # account isn't linked to a Sure account.
  def process
    unless fio_account.current_account.present?
      Rails.logger.info "FioAccount::Processor - No linked account for fio_account #{fio_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "FioAccount::Processor - Failed to process account fio_account_id=#{fio_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    # Update the linked Sure account's balance/currency from the statement header.
    def process_account!
      account = fio_account.current_account
      balance = fio_account.current_balance || 0
      currency = parse_currency(fio_account.currency) || account.currency

      # A drawn overdraft, loan or mortgage is reported negative by Fio; Sure holds a
      # liability as a positive balance.
      balance = balance.abs if account.accountable_type == "Loan"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    # Delegate to the transactions processor, capturing and logging failures.
    def process_transactions
      FioAccount::Transactions::Processor.new(fio_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "FioAccount::Processor - Failed to process transactions fio_account_id=#{fio_account.id} error_class=#{e.class.name}"
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process transactions",
        source: self.class.name,
        provider_key: "fio",
        family: fio_account.fio_item.family,
        account_provider: fio_account.account_provider,
        metadata: { fio_account_id: fio_account.id, error_class: e.class.name, error_message: e.message }
      )
      { success: false, failed: 1, errors: [ { error: I18n.t("fio_item.errors.account_processing_failed") } ] }
    end

    # Report a processing error to Sentry with a sanitized message and tags.
    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Fio account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          fio_account_id: fio_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "fio_account_processor",
          {
            fio_account_id: fio_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code #{currency_value.inspect} for Fio account #{fio_account.id}, falling back to account currency")
    end
end
