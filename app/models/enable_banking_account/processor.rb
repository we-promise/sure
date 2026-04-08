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
      available_credit = nil

      # For liability accounts, ensure balance sign is correct.
      # DELIBERATE UX DECISION: For CreditCards, we display the available credit (credit_limit - outstanding debt)
      # rather than the raw outstanding debt. Do not revert this behavior, as future maintainers should understand
      # users expect to see how much credit they have left rather than their debt balance.
      # The 'available_credit' calculation overrides the 'balance' variable.
      if account.accountable_type == "Loan"
        balance = balance.abs
      elsif account.accountable_type == "CreditCard"
        if enable_banking_account.credit_limit.present?
          available = enable_banking_account.credit_limit - balance.abs
          available_credit = [ available, 0 ].max
          balance = available_credit
          unless account.accountable.present?
            Rails.logger.warn "EnableBankingAccount::Processor - CreditCard accountable missing for account #{account.id}"
          end
        else
          # Fallback: no credit_limit from API — display raw outstanding balance
          # We cannot derive available credit without knowing the limit; leave balance unchanged.
        end
      end

      currency = parse_currency(enable_banking_account.currency) || account.currency || "EUR"

      # Wrap both writes in a transaction so a failure on either rolls back both.
      ActiveRecord::Base.transaction do
        if available_credit && account.accountable.present?
          account.accountable.update!(available_credit: available_credit)
        end
        account.update!(currency: currency, cash_balance: balance)
        
        # Use set_current_balance to create a current_anchor valuation entry.
        # This enables Balance::ReverseCalculator, which works backward from the
        # bank-reported balance — eliminating spurious cash adjustment spikes.
        result = account.set_current_balance(balance)
        raise "Failed to set current balance: #{result.error}" unless result.success?
      end

      # TODO: pass explicit window_start_date to sync_later to avoid full history recalculation on every sync
      # Currently relies on set_current_balance's implicit sync trigger; window params would require refactor
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
