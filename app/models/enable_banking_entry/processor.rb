class EnableBankingEntry::Processor
  # enable_banking_transaction is the raw hash fetched from Enable Banking API and converted to JSONB
  def initialize(enable_banking_transaction, enable_banking_account:)
    @enable_banking_transaction = enable_banking_transaction
    @enable_banking_account = enable_banking_account
  end

  def process
    EnableBankingAccount.transaction do
      entry = account.entries.find_or_initialize_by(plaid_id: enable_banking_id) do |e|
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

      if merchant
        entry.transaction.enrich_attribute(
          :merchant_id,
          merchant.id,
          source: "enable_banking"
        )
      end
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
      enable_banking_transaction.dig("bank_transaction_code", "description") || enable_banking_transaction.dig("remittance_information")&.first
    end

    def notes
      Array(enable_banking_transaction.dig("remittance_information")).join(" ")
    end

    def credit_debit_indicator
      enable_banking_transaction.dig("credit_debit_indicator")
    end

    def calculate_signed_amount
      amt = enable_banking_transaction.dig("transaction_amount", "amount").to_d
      credit_debit_indicator == "CRDT" ? -amt : amt
    end

    def currency
      enable_banking_transaction.dig("transaction_amount", "currency")
    end

    def date
      enable_banking_transaction.dig("value_date")
    end

    def merchant
      merchant_name = enable_banking_transaction.dig("creditor", "name")

      return nil unless merchant_name.present?

      ProviderMerchant.find_or_create_by!(
        source: "enable_banking",
        name: merchant_name,
      ) do |m|
        m.provider_merchant_id = merchant_name # There is no ID available in Enable Banking API, using name instead
      end
    end
end
