class LunchflowAccount::Processor
  attr_reader :lunchflow_account

  def initialize(lunchflow_account)
    @lunchflow_account = lunchflow_account
  end

  def process
    unless lunchflow_account.current_account.present?
      Rails.logger.info "LunchflowAccount::Processor - No linked account for lunchflow_account #{lunchflow_account.id}, skipping processing"
      return
    end

    Rails.logger.info "LunchflowAccount::Processor - Processing lunchflow_account #{lunchflow_account.id} (account #{lunchflow_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "LunchflowAccount::Processor - Failed to process account #{lunchflow_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if lunchflow_account.current_account.blank?
        Rails.logger.error("Lunchflow account #{lunchflow_account.id} has no associated Account")
        return
      end

      # Update account balance from latest Lunchflow data
      account = lunchflow_account.current_account
      balance = lunchflow_account.current_balance || 0

      # For credit cards and loans, ensure positive balances
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = balance.abs
      end

      account.update!(
        balance: balance,
        cash_balance: balance
      )
    end

    def process_transactions
      LunchflowAccount::Transactions::Processor.new(lunchflow_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          lunchflow_account_id: lunchflow_account.id,
          context: context
        )
      end
    end
end
