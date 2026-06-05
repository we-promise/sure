class AkahuAccount::Processor
  include CurrencyNormalizable

  SanitizedProcessingError = Class.new(StandardError)

  attr_reader :akahu_account

  def initialize(akahu_account)
    @akahu_account = akahu_account
  end

  def process
    unless akahu_account.current_account.present?
      Rails.logger.info "AkahuAccount::Processor - No linked account for akahu_account #{akahu_account.id}, skipping processing"
      return
    end

    process_account!
    process_transactions
  rescue StandardError => e
    Rails.logger.error "AkahuAccount::Processor - Failed to process account akahu_account_id=#{akahu_account.id} error_class=#{e.class.name}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = akahu_account.current_account
      balance = akahu_account.current_balance || 0

      balance = balance.abs if account.accountable_type.in?(%w[CreditCard Loan])
      cash_balance = account.accountable_type == "Investment" ? 0 : balance
      currency = parse_currency(akahu_account.currency) || account.currency || "NZD"

      account.update!(
        balance: balance,
        cash_balance: cash_balance,
        currency: currency
      )
    end

    def process_transactions
      AkahuAccount::Transactions::Processor.new(akahu_account).process
    rescue => e
      report_exception(e, "transactions")
      Rails.logger.error "AkahuAccount::Processor - Failed to process transactions akahu_account_id=#{akahu_account.id} error_class=#{e.class.name}"
      { success: false, failed: 1, errors: [ { error: I18n.t("akahu_item.errors.account_processing_failed") } ] }
    end

    def report_exception(error, context)
      safe_error = SanitizedProcessingError.new("Akahu account processing failed")

      Sentry.capture_exception(safe_error) do |scope|
        scope.set_tags(
          akahu_account_id: akahu_account.id,
          context: context,
          error_class: error.class.name
        )
        scope.set_context(
          "akahu_account_processor",
          {
            akahu_account_id: akahu_account.id,
            context: context,
            error_class: error.class.name
          }
        )
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Akahu account #{akahu_account.id}, falling back to account currency")
    end
end
