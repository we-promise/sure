# SimpleFin Account importer - imports SimpleFin account data into Maybe accounts
class SimplefinAccount::Importer
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def import
    return unless simplefin_account.account.present?

    # Update account attributes from SimpleFin data
    update_account_attributes

    # Update balance information
    update_balance_information
  end

  private
    attr_reader :simplefin_account

    def account
      simplefin_account.account
    end

    def update_account_attributes
      # Update name if it's been enriched from SimpleFin
      if simplefin_account.name.present?
        account.enrich_attributes(
          { name: simplefin_account.name },
          source: "simplefin"
        )
      end
    end

    def update_balance_information
      # Update balance based on account type
      balance = calculate_balance
      cash_balance = calculate_cash_balance

      account.assign_attributes(
        balance: balance,
        currency: simplefin_account.currency || "USD",
        cash_balance: cash_balance
      )

      account.save!

      # Set current balance anchor for event-sourced ledger
      account.set_current_balance(balance)
    end

    def calculate_balance
      if account.accountable_type == "Investment"
        balance_calculator.balance
      else
        # For non-investment accounts, use direct balance
        balance = simplefin_account.current_balance || 0

        # For liabilities (credit cards, loans), ensure positive balance
        if account.classification == "liability" && balance < 0
          balance.abs
        else
          balance
        end
      end
    end

    def calculate_cash_balance
      if account.accountable_type == "Investment"
        balance_calculator.cash_balance
      else
        # For non-investment accounts, cash balance equals total balance
        calculate_balance
      end
    end

    def balance_calculator
      @balance_calculator ||= SimplefinAccount::Investments::BalanceCalculator.new(simplefin_account)
    end
end
