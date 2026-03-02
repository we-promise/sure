class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, exchange_rate: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d

    if exchange_rate.present?
      rate_value = exchange_rate.to_d
      raise ArgumentError, "exchange_rate must be greater than 0" unless rate_value > 0
      @exchange_rate = rate_value
    else
      @exchange_rate = nil
    end
  end

  def create
    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed"
    )

    if transfer.save
      source_account.sync_later
      destination_account.sync_later
    end

    transfer
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :exchange_rate

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"
      kind = outflow_transaction_kind

      Transaction.new(
        kind: kind,
        category: (investment_contributions_category if kind == "investment_contribution"),
        entry: source_account.entries.build(
          amount: amount.abs,
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
        entry: destination_account.entries.build(
          amount: inflow_converted_money.amount.abs * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true, # Protect from provider sync claiming this entry
        )
      )
    end

    # If destination account has different currency, its transaction should show up as converted
    # Uses user-provided exchange rate if available, otherwise fetches from provider with 1:1 fallback
    def inflow_converted_money
      Money.new(amount.abs, source_account.currency)
           .exchange_to(
             destination_account.currency,
             date: date,
             custom_rate: exchange_rate,
             fallback_rate: 1.0
           )
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
end
