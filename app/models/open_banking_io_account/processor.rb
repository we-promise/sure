class OpenBankingIoAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :open_banking_io_account

  def initialize(open_banking_io_account)
    @open_banking_io_account = open_banking_io_account
  end

  def process
    unless open_banking_io_account.current_account.present?
      Rails.logger.info "OpenBankingIoAccount::Processor - No linked account for open_banking_io_account #{open_banking_io_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "OpenBankingIoAccount::Processor - Failed to process account open_banking_io_account_id=#{open_banking_io_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = open_banking_io_account.current_account
      currency = parse_currency(open_banking_io_account.currency) || account.currency || OpenBankingIoAccount::DEFAULT_CURRENCY

      attributes = { currency: currency }

      # Only touch the balance when the feed actually carried a booked balance.
      # When a bank returns only an available (ITAV) balance the snapshot leaves
      # current_balance nil; coercing that to 0 would overwrite the real account
      # balance with zero on every sync, so skip the balance update entirely.
      unless open_banking_io_account.current_balance.nil?
        attributes[:balance] = open_banking_io_account.normalized_balance_for(account.accountable_type)
        attributes[:cash_balance] = open_banking_io_account.cash_balance_for(account.accountable_type)
      end

      account.update!(**attributes)
    end

    def process_transactions
      OpenBankingIoAccount::Transactions::Processor.new(open_banking_io_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "OpenBankingIoAccount::Processor - Failed to process transactions open_banking_io_account_id=#{open_banking_io_account.id} error_class=#{e.class.name}"
      { success: false, failed: 1, errors: [ { error: I18n.t("open_banking_io_item.errors.account_processing_failed") } ] }
    end

    def report_exception(error, context)
      # Also record it on /settings/debug, per the repo's provider-diagnostics convention --
      # the Sentry report below is deliberately message-free, which left support with
      # nothing filterable by provider or family. Mirrors UpAccount::Processor.
      open_banking_io_account.open_banking_io_item&.capture_provider_error(
        "Failed to process open-banking.io account #{context}",
        error: error,
        open_banking_io_account_id: open_banking_io_account.id,
        account_provider: open_banking_io_account.account_provider,
        context: context
      )

      safe_error = SanitizedProcessingError.new("open-banking.io account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          open_banking_io_account_id: open_banking_io_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "open_banking_io_account_processor",
          {
            open_banking_io_account_id: open_banking_io_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for open-banking.io account #{open_banking_io_account.id}, falling back to account currency")
    end
end
