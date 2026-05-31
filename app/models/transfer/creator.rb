class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, exchange_rate: nil, split_loan_payment: true)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @split_loan_payment = split_loan_payment

    if exchange_rate.present?
      rate_value = exchange_rate.to_d
      raise ArgumentError, "exchange_rate must be greater than 0" unless rate_value > 0
      @exchange_rate = rate_value
    else
      @exchange_rate = nil
    end
  end

  def create
    Transfer.transaction do
      transfer = Transfer.new(
        inflow_transaction: inflow_transaction,
        outflow_transaction: outflow_transaction,
        status: "confirmed"
      )

      if transfer.save
        loan_interest_transaction&.save!
        source_account.sync_later
        destination_account.sync_later
      end

      transfer
    end
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :exchange_rate, :split_loan_payment

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"
      kind = outflow_transaction_kind

      Transaction.new(
        kind: kind,
        extra: loan_payment_extra,
        category: (investment_contributions_category if kind == "investment_contribution"),
        entry: source_account.entries.build(
          amount: outflow_amount.abs,
          currency: source_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    def investment_contributions_category
      source_account.family.investment_contributions_category
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      Transaction.new(
        kind: "funds_movement",
        extra: loan_payment_extra,
        entry: destination_account.entries.build(
          amount: inflow_amount.abs * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    # If destination account has different currency, its transaction should show up as converted
    # Uses user-provided exchange rate if available, otherwise requires a provider rate
    def inflow_converted_money
      Money.new(amount.abs, source_account.currency)
           .exchange_to(
             destination_account.currency,
             date: date,
             custom_rate: exchange_rate
           )
    end

    def outflow_amount
      return loan_principal_transfer_amount if split_annuity_loan_payment?

      amount
    end

    def inflow_amount
      return Money.new(loan_principal_transfer_amount.abs, source_account.currency)
           .exchange_to(destination_account.currency, date: date, custom_rate: exchange_rate)
           .amount if split_annuity_loan_payment?

      inflow_converted_money.amount
    end

    # The "expense" side of a transfer is treated different in analytics based on where it goes.
    def outflow_transaction_kind
      if destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      elsif destination_is_investment? && !source_is_investment?
        "investment_contribution"
      else
        "funds_movement"
      end
    end

    def destination_is_investment?
      destination_account.investment? || destination_account.crypto?
    end

    def source_is_investment?
      source_account.investment? || source_account.crypto?
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end

    def split_annuity_loan_payment?
      loan_payment_split&.matched?
    end

    def loan_principal_transfer_amount
      split_principal_amount || amount
    end

    def split_principal_amount
      return nil unless loan_payment_split&.matched?

      loan_payment_split.principal + loan_payment_split.extra_principal
    end

    def loan_payment_split
      return @loan_payment_split if defined?(@loan_payment_split)
      return @loan_payment_split = nil unless split_loan_payment
      return @loan_payment_split = nil unless destination_account.loan? && destination_account.loan.annuity_enabled?

      @loan_payment_split = Loan::PaymentSplitter.new(destination_account.loan).split(
        payment_date: date,
        amount: amount
      )
    end

    def loan_payment_extra
      return {} unless split_annuity_loan_payment?

      {
        "loan_payment_split" => {
          "period_number" => loan_payment_split.period_number,
          "due_date" => loan_payment_split.due_date.to_s,
          "interest" => loan_payment_split.interest.to_s,
          "principal" => loan_payment_split.principal.to_s,
          "extra_principal" => loan_payment_split.extra_principal.to_s,
          "variance" => loan_payment_split.variance.to_s,
          "scheduled_payment" => loan_payment_split.scheduled_payment.to_s
        }
      }
    end

    def loan_interest_transaction
      return @loan_interest_transaction if defined?(@loan_interest_transaction)
      return @loan_interest_transaction = nil unless split_annuity_loan_payment?
      return @loan_interest_transaction = nil unless loan_payment_split.interest.positive?

      @loan_interest_transaction = Transaction.new(
        kind: "standard",
        extra: loan_payment_extra,
        entry: source_account.entries.build(
          amount: loan_payment_split.interest,
          currency: source_account.currency,
          date: date,
          name: "Interest for #{destination_account.name}",
          user_modified: true
        )
      )
    end
end
