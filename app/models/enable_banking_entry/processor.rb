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
        amount: amount,
        currency: currency,
        date: date
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
      enable_banking_transaction["entry_reference"]
    end

    def name
      enable_banking_transaction["remittance_information"].join(" ")
    end

    def amount
      enable_banking_transaction["transaction_amount"]["amount"]
    end

    def currency
      enable_banking_transaction["transaction_amount"]["currency"]
    end

    def date
      enable_banking_transaction["booking_date"]
    end
end
