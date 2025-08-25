class DirectBank::TransactionProcessor
  def initialize(bank_account, transactions_data)
    @bank_account = bank_account
    @account = bank_account.account
    @transactions_data = transactions_data
  end

  def process
    return [] unless @account.present?

    processed_transactions = []

    @transactions_data.each do |transaction_data|
      transaction = find_or_create_transaction(transaction_data)
      processed_transactions << transaction if transaction
    end

    processed_transactions
  end

  private

  def find_or_create_transaction(transaction_data)
    existing = find_existing_transaction(transaction_data)
    return existing if existing

    create_transaction(transaction_data)
  end

  def find_existing_transaction(transaction_data)
    @account.transactions.find_by(
      date: transaction_data[:date],
      amount: transaction_data[:amount],
      external_id: transaction_data[:external_id]
    )
  end

  def create_transaction(transaction_data)
    @account.transactions.create!(
      date: transaction_data[:date],
      amount: transaction_data[:amount],
      name: transaction_data[:description],
      pending: transaction_data[:pending],
      external_id: transaction_data[:external_id],
      merchant: transaction_data[:merchant_name],
      category: find_or_create_category(transaction_data[:category]),
      metadata: transaction_data[:raw_data]
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to create transaction: #{e.message}"
    nil
  end

  def find_or_create_category(category_name)
    return nil unless category_name.present?

    @account.family.categories.find_or_create_by(name: category_name)
  end
end