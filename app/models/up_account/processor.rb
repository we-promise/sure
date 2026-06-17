class UpAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :up_account

  def initialize(up_account)
    @up_account = up_account
  end

  def process
    unless up_account.current_account.present?
      Rails.logger.info "UpAccount::Processor - No linked account for up_account #{up_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "UpAccount::Processor - Failed to process account up_account_id=#{up_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = up_account.current_account
      balance = up_account.current_balance || 0

      # Loan balances are stored as positive debt in Sure regardless of Up's sign.
      balance = balance.abs if account.accountable_type == "Loan"
      currency = parse_currency(up_account.currency) || account.currency || "AUD"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    def process_transactions
      UpAccount::Transactions::Processor.new(up_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "UpAccount::Processor - Failed to process transactions up_account_id=#{up_account.id} error_class=#{e.class.name}"
      { success: false, failed: 1, errors: [ { error: I18n.t("up_item.errors.account_processing_failed") } ] }
    end

    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Up account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          up_account_id: up_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "up_account_processor",
          {
            up_account_id: up_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Up account #{up_account.id}, falling back to account currency")
    end
end
