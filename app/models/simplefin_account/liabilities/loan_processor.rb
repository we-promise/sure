# SimpleFin Loan processor for loan-specific features
class SimplefinAccount::Liabilities::LoanProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return unless simplefin_account.account&.accountable_type == "Loan"

    # Update loan specific attributes if available
    update_loan_attributes
  end

  private
    attr_reader :simplefin_account

    def account
      simplefin_account.account
    end

    def update_loan_attributes
      # I don't know if SimpleFin typically provide detailed loan metadata
      # like interest rates, terms, etc. but we can update what's available

      # For now, just ensure the balance is properly set as positive for liabilities
      current_balance = simplefin_account.current_balance
      if current_balance && current_balance < 0
        # Loan balances should be positive (amount owed)
        account.update!(balance: current_balance.abs)
      end
    end
end
