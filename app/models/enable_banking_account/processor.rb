class EnableBankingAccount::Processor
  class ProcessingError < StandardError; end
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
      balance = enable_banking_account.current_balance

      # A nil current_balance means this sync's balance fetch did not succeed:
      # upsert_enable_banking_snapshot! clears it and only a successful
      # balance fetch repopulates it. Coercing nil to 0 here would persist a
      # zero balance (and a zero current_anchor valuation) onto a healthy
      # account whenever the provider has a transient failure, so leave the
      # account untouched instead.
      if balance.nil?
        Rails.logger.warn("EnableBankingAccount::Processor - No balance available for enable_banking_account #{enable_banking_account.id} (balance fetch failed or not yet run), skipping account update")
        return
      end

      available_credit = nil

      # For liability accounts, ensure balance sign is correct.
      # For CreditCards, we expect the main balance to reflect the absolute outstanding debt
      # rather than available credit, to ensure net worth calculations handle the liability accurately.
      # Any available credit metrics (from limits) are instead stored safely as metadata on the Accountable.
      # Loans and CreditCards must always represent their outstanding balance as an absolute
      # positive debt amount, regardless of the API's reported sign, to ensure the BalanceSheet
      # calculates net worth accurately.
      if account.accountable_type == "Loan" || account.accountable_type == "CreditCard"
        # Standardize the raw balance to an absolute positive debt
        outstanding_debt = balance.abs
        balance = outstanding_debt

        if account.accountable_type == "CreditCard"
          if enable_banking_account.treat_balance_as_available_credit?
            if enable_banking_account.credit_limit.present?
              # When the API returns the available credit as the current balance,
              # we need to calculate the outstanding debt using the credit limit.
              # Use .max(0) to prevent synthetic debt on overpaid cards.
              outstanding_debt = [ enable_banking_account.credit_limit - balance, 0 ].max
              available_credit = balance

              balance = outstanding_debt

              unless account.accountable.present?
                DebugLogEntry.capture(
                  category: "sync",
                  level: "warn",
                  message: "CreditCard accountable missing for account",
                  source: "EnableBankingAccount::Processor",
                  account: account
                )
              end
            else
              # No credit limit from API. We cannot reverse available credit to absolute debt
              # without knowing the total limit. Fall back to absolute balance.
              DebugLogEntry.capture(
                category: "sync",
                level: "warn",
                message: "Cannot compute debt from available credit because credit_limit is blank",
                source: "EnableBankingAccount::Processor",
                account: account
              )
              available_credit = balance
            end
          else
            # Default behavior: API returns outstanding debt
            if enable_banking_account.credit_limit.present?
              available_credit = [ enable_banking_account.credit_limit - outstanding_debt, 0 ].max
            elsif account.accountable&.available_credit.present?
              # No limit from API, but we have stored available_credit metadata
              available_credit = account.accountable.available_credit
            end
          end
        end
      end

      currency = parse_currency(enable_banking_account.currency) || account.currency || "EUR"

      # Wrap both writes in a transaction so a failure on either rolls back both.
      ActiveRecord::Base.transaction do
        if account.accountable.present? && account.accountable.respond_to?(:available_credit=)
          account.accountable.update!(available_credit: available_credit)
        end
        account.update!(currency: currency, cash_balance: balance)

        # Use set_current_balance to create a current_anchor valuation entry.
        # This enables Balance::ReverseCalculator, which works backward from the
        # bank-reported balance — eliminating spurious cash adjustment spikes.
        result = account.set_current_balance(balance)
        raise ProcessingError, "Failed to set current balance: #{result.error}" unless result.success?
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
