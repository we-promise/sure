class EnableBankingAccount::Processor
  include EnableBankingAccount::TypeMappable

  attr_reader :enable_banking_account

  def initialize(enable_banking_account)
    @enable_banking_account = enable_banking_account
  end

  # Each step represents a different Enable Banking API endpoint
  #
  # Processing the account is the first step and if it fails, we halt the entire processor
  # Each subsequent step can fail independently, but we continue processing the rest of the steps
  def process
    process_account!
    process_transactions
  end

  private
    def family
      enable_banking_account.enable_banking_item.family
    end

    def process_account!
      EnableBankingAccount.transaction do
        account = family.accounts.find_or_initialize_by(
          enable_banking_account_id: enable_banking_account.id
        )

        # Create or assign the accountable if needed
        if account.accountable.nil?
          accountable = map_accountable(enable_banking_account.account_type)
          account.accountable = accountable
        end

        # Name and subtype are the attributes a user can override for Plaid accounts
        # Use enrichable pattern to respect locked attributes
        account.enrich_attributes(
          {
            name: enable_banking_account.name
          },
          source: "enable_banking"
        )

        account.assign_attributes(
          balance: balance_calculator.balance,
          currency: enable_banking_account.currency,
          cash_balance: balance_calculator.cash_balance
        )

        account.save!

        # Create or update the current balance anchor valuation for event-sourced ledger
        account.set_current_balance(balance_calculator.balance)
      end
    end

    def process_transactions
      return unless enable_banking_account.raw_transactions_payload.present?

      transactions_data = enable_banking_account.raw_transactions_payload
      transactions_data&.each do |transaction|
        begin
          EnableBankingEntry::Processor.new(
            transaction,
            enable_banking_account: enable_banking_account
          ).process
        rescue => e
          report_exception(e)
        end
      end
    end

    def balance_calculator
      balance = enable_banking_account.current_balance || enable_banking_account.available_balance || 0
      # We don't currently distinguish "cash" vs. "non-cash" balances for non-investment accounts.
      OpenStruct.new(
          balance: balance,
          cash_balance: balance
      )
    end

    def report_exception(error)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(enable_banking_account_id: enable_banking_account.id)
      end
    end
end
