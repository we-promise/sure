class SimplefinAccount::Processor
  attr_reader :simplefin_account

  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  # Each step represents different SimpleFin data processing
  # Processing the account is the first step and if it fails, we halt
  # Each subsequent step can fail independently, but we continue processing
  def process
    # If the account is missing (e.g., user deleted the connection and re‑linked later),
    # do not auto‑link. Relinking is now a manual, user‑confirmed flow via the Relink modal.
    unless simplefin_account.current_account.present?
      return
    end

    process_account!
    # Ensure provider link exists after processing the account/balance
    begin
      simplefin_account.ensure_account_provider!
    rescue => e
      Rails.logger.warn("SimpleFin provider link ensure failed for #{simplefin_account.id}: #{e.class} - #{e.message}")
    end
    process_transactions
    process_investments
    process_liabilities
  end

  private

    def process_account!
      # This should not happen in normal flow since accounts are created manually
      # during setup, but keeping as safety check
      if simplefin_account.current_account.blank?
        Rails.logger.error("SimpleFin account #{simplefin_account.id} has no associated Account - this should not happen after manual setup")
        return
      end

      # Update account balance and cash balance from latest SimpleFin data
      account = simplefin_account.current_account
      balance = simplefin_account.current_balance || simplefin_account.available_balance || 0

      # SimpleFIN balance convention matches our app convention:
      # - Positive balance = debt (you owe money)
      # - Negative balance = credit balance (bank owes you, e.g., overpayment)
      # No sign conversion needed - pass through as-is (same as Plaid)

      # Calculate cash balance correctly for investment accounts
      cash_balance = if account.accountable_type == "Investment"
        calculator = SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
        calculator.cash_balance
      else
        balance
      end

      account.update!(
        balance: balance,
        cash_balance: cash_balance,
        currency: simplefin_account.currency
      )
    end

    def process_transactions
      SimplefinAccount::Transactions::Processor.new(simplefin_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def process_investments
      return unless simplefin_account.current_account&.accountable_type == "Investment"
      SimplefinAccount::Investments::TransactionsProcessor.new(simplefin_account).process
      SimplefinAccount::Investments::HoldingsProcessor.new(simplefin_account).process
    rescue => e
      report_exception(e, "investments")
    end

    def process_liabilities
      case simplefin_account.current_account&.accountable_type
      when "CreditCard"
        SimplefinAccount::Liabilities::CreditProcessor.new(simplefin_account).process
      when "Loan"
        SimplefinAccount::Liabilities::LoanProcessor.new(simplefin_account).process
      end
    rescue => e
      report_exception(e, "liabilities")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          simplefin_account_id: simplefin_account.id,
          context: context
        )
      end
    end
end
