class AkahuAccount::Processor
  include CurrencyNormalizable

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
    Rails.logger.error "AkahuAccount::Processor - Failed to process account #{akahu_account.id}: #{e.message}"
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
      { success: false, failed: 1, errors: [ { error: e.message } ] }
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          akahu_account_id: akahu_account.id,
          context: context
        )
      end
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Akahu account #{akahu_account.id}, falling back to account currency")
    end
end
