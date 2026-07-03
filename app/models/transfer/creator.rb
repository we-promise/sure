class Transfer::Creator
  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, exchange_rate: nil, source_fee_amount: nil, destination_fee_amount: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @source_fee_amount = source_fee_amount.to_d
    @destination_fee_amount = destination_fee_amount.to_d

    if exchange_rate.present?
      rate_value = exchange_rate.to_d
      raise ArgumentError, "exchange_rate must be greater than 0" unless rate_value > 0
      @exchange_rate = rate_value
    else
      @exchange_rate = nil
    end
  end

  def create
    raise ArgumentError, "source_fee_amount must be non-negative" if source_fee_amount.negative?
    raise ArgumentError, "destination_fee_amount must be non-negative" if destination_fee_amount.negative?

    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed",
      amount: amount
    )

    Transfer.transaction do
      if source_fee_amount > 0
        transfer.fee_transactions << build_source_fee_transaction
      end
      if destination_fee_amount > 0
        transfer.fee_transactions << build_destination_fee_transaction
      end
      transfer.save!
    end

    source_account.sync_later
    destination_account.sync_later

    transfer
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :exchange_rate, :source_fee_amount, :destination_fee_amount

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"
      kind = outflow_transaction_kind

      Transaction.new(
        kind: kind,
        category: (investment_contributions_category if kind == "investment_contribution"),
        entry: source_account.entries.build(
          amount: amount,
          currency: source_account.currency,
          date: date,
          name: name,
          user_modified: true,
        )
      )
    end

    def investment_contributions_category
      source_account.family.investment_contributions_category
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      net_inflow = inflow_converted_amount

      Transaction.new(
        kind: "funds_movement",
        entry: destination_account.entries.build(
          amount: net_inflow * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true,
        )
      )
    end

    def build_source_fee_transaction
      fee_category = find_or_create_fees_category(source_account.family)
      Transaction.new(
        kind: "standard",
        category: fee_category,
        entry: source_account.entries.build(
          amount: source_fee_amount,
          currency: source_account.currency,
          date: date,
          name: "Transfer fee — #{name_prefix} to #{destination_account.name}",
        )
      )
    end

    def build_destination_fee_transaction
      fee_category = find_or_create_fees_category(destination_account.family)
      Transaction.new(
        kind: "standard",
        category: fee_category,
        entry: destination_account.entries.build(
          amount: destination_fee_amount,
          currency: destination_account.currency,
          date: date,
          name: "Transfer fee — #{name_prefix} from #{source_account.name}",
        )
      )
    end

    def find_or_create_fees_category(family)
      family.categories.find_or_create_by!(name: I18n.t("models.category.defaults.fees"))
    end

    def inflow_converted_amount
      Money.new(amount.abs, source_account.currency)
           .exchange_to(
             destination_account.currency,
             date: date,
             custom_rate: exchange_rate
           ).amount
    end

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
