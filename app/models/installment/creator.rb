class Installment::Creator
  attr_reader :installment, :source_account_id

  def initialize(installment, source_account_id: nil)
    @installment = installment
    @source_account_id = source_account_id
  end

  def call
    ActiveRecord::Base.transaction do
      generate_historical_transactions
      create_recurring_payment if source_account_id.present?
      update_account_balances
    end
  end

  private

    def generate_historical_transactions
      # Skip if no payments have been made yet
      return if installment.current_term.zero?

      schedule = installment.generate_payment_schedule
      account = installment.account

      # Create transactions for payments 1 through current_term
      schedule.first(installment.current_term).each do |payment_info|
        transaction = Transaction.create!(
          extra: {
            "installment_id" => installment.id.to_s,
            "installment_payment_number" => payment_info[:payment_number]
          },
          kind: "loan_payment"
        )

        account.entries.create!(
          entryable: transaction,
          amount: -payment_info[:amount], # Negative because it's a payment (outflow)
          currency: installment.currency,
          date: payment_info[:date],
          name: "#{account.name} - Payment #{payment_info[:payment_number]} of #{installment.total_term}"
        )
      end
    end

    def create_recurring_payment
      source_account = Account.find_by(id: source_account_id)
      return unless source_account

      family = installment.account.family
      next_payment_date = installment.next_payment_date || installment.first_payment_date

      # Calculate expected day of month from the next payment date
      expected_day = next_payment_date.day

      # For last_occurrence_date, use calculated most recent payment if available, otherwise use first payment date
      last_occurrence = if installment.current_term > 0
        installment.calculated_most_recent_payment_date
      else
        installment.first_payment_date
      end

      RecurringTransaction.create!(
        family: family,
        installment_id: installment.id,
        name: "#{installment.account.name} payment",
        amount: -installment.installment_cost, # Negative for outflow
        currency: installment.currency,
        expected_day_of_month: expected_day,
        last_occurrence_date: last_occurrence,
        next_expected_date: next_payment_date,
        status: "active",
        occurrence_count: installment.current_term,
        manual: true
      )
    end

    def update_account_balances
      account = installment.account
      current_balance = installment.calculate_current_balance

      # Update the account's balance to reflect the calculated current balance
      account.update!(balance: current_balance)

      # Create a balance record for today with the calculated balance
      account.balances.find_or_create_by!(date: Date.current) do |balance|
        balance.balance = current_balance
        balance.currency = installment.currency
      end
    end
end
