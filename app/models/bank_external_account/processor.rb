class BankExternalAccount::Processor
  attr_reader :ext_account, :mapper

  def initialize(ext_account, mapper:)
    @ext_account = ext_account
    @mapper = mapper
  end

  def process
    ensure_account_exists
    process_transactions
  end

  private

    def ensure_account_exists
      return if ext_account.account.present?
      Rails.logger.error("External bank account #{ext_account.id} is not linked to an Account")
    end

    def process_transactions
      return unless ext_account.raw_transactions_payload.present?

      account = ext_account.account
      Array(ext_account.raw_transactions_payload).each do |tx_payload|
        process_transaction(account, tx_payload)
      end
    end

    def process_transaction(account, tx_payload)
      normalized = mapper.normalize_transaction(tx_payload, currency: account.currency)

      external_id = normalized[:external_id]
      posted_date = normalized[:posted_at]
      amount = normalized[:amount]
      name = normalized[:description]

      existing_entry = Entry.find_by(plaid_id: external_id)
      return if existing_entry

      transaction = Transaction.new(external_id: external_id)

      Entry.create!(
        account: account,
        name: name,
        amount: amount,
        date: posted_date,
        currency: account.currency,
        entryable: transaction,
        plaid_id: external_id
      )
    rescue => e
      Rails.logger.error("Failed to process bank transaction #{tx_payload.inspect}: #{e.message}")
    end
end

