class EnableBankingAccount::Processor
  include CurrencyNormalizable

  attr_reader :enable_banking_account

  def initialize(enable_banking_account)
    @enable_banking_account = enable_banking_account
  end

  def process
    unless enable_banking_account.current_account.present?
      Rails.logger.info "EnableBankingAccount::Processor - No linked account for enable_banking_account #{enable_banking_account.id}, skipping processing"
      return
    end

    Rails.logger.info "EnableBankingAccount::Processor - Processing enable_banking_account #{enable_banking_account.id} (uid #{enable_banking_account.uid})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "EnableBankingAccount::Processor - Failed to process account #{enable_banking_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if enable_banking_account.current_account.blank?
        Rails.logger.error("Enable Banking account #{enable_banking_account.id} has no associated Account")
        return
      end

      account = enable_banking_account.current_account
      balance = enable_banking_account.current_balance || 0

      # For credit cards, compute balance based on credit limit
      if account.accountable_type == "CreditCard"
        available_credit = account.accountable.available_credit || 0
        balance = available_credit - balance
      # For liability accounts, ensure positive balances
      elsif account.accountable_type == "Loan"
        balance = -balance
      end

      currency = parse_currency(enable_banking_account.currency) || account.currency || "EUR"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    def process_transactions
      EnableBankingAccount::Transactions::Processor.new(enable_banking_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          enable_banking_account_id: enable_banking_account.id,
          context: context
        )
      end
    end
end
