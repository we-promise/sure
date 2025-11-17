class EnableBankingEntry::Processor
  # enable_banking_transaction is the raw hash fetched from Enable Banking API and converted to JSONB
  def initialize(enable_banking_transaction, enable_banking_account:)
    @enable_banking_transaction = enable_banking_transaction
    @enable_banking_account = enable_banking_account
  end

  def process
    EnableBankingAccount.transaction do
      entry = account.entries.find_or_initialize_by(plaid_id: enable_banking_id) do |e| #TODO change plaid_id to enable_banking_id?
        e.entryable = Transaction.new
      end

      entry.assign_attributes(
        amount: calculate_signed_amount,
        currency: currency,
        date: date,
        notes: notes
      )

      entry.enrich_attribute(
        :name,
        name,
        source: "enable_banking"
      )

    end
  end

  private
    attr_reader :enable_banking_transaction, :enable_banking_account, :category_matcher

    def account
      enable_banking_account.account
    end

    def enable_banking_id
      enable_banking_transaction.dig("entry_reference")
    end

    def name
      enable_banking_transaction.dig("bank_transaction_code", "description")
    end

    def notes
      enable_banking_transaction.dig("remittance_information").join(" ")
    end

    def credit_debit_indicator
      enable_banking_transaction.dig("credit_debit_indicator")
    end

    def calculate_signed_amount
      amount = enable_banking_transaction.dig("transaction_amount", "amount").to_f
      credit_debit_indicator = enable_banking_transaction.dig("credit_debit_indicator")
      signed_amount = credit_debit_indicator == "CRDT" ? amount.to_d * -1 : amount.to_d
      signed_amount
    end

    def currency
      enable_banking_transaction.dig("transaction_amount", "currency")
    end

    def date
      enable_banking_transaction.dig("value_date")
    end
end
