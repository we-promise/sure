class LunchflowAccount::Transactions::Processor
  attr_reader :lunchflow_account

  def initialize(lunchflow_account)
    @lunchflow_account = lunchflow_account
  end

  def process
    unless lunchflow_account.raw_transactions_payload.present?
      Rails.logger.info "LunchflowAccount::Transactions::Processor - No transactions in raw_transactions_payload for lunchflow_account #{lunchflow_account.id}"
      return
    end

    Rails.logger.info "LunchflowAccount::Transactions::Processor - Processing #{lunchflow_account.raw_transactions_payload.count} transactions for lunchflow_account #{lunchflow_account.id}"

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    lunchflow_account.raw_transactions_payload.each do |transaction_data|
      LunchflowEntry::Processor.new(
        transaction_data,
        lunchflow_account: lunchflow_account
      ).process
    rescue => e
      Rails.logger.error "Error processing Lunchflow transaction: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end
end
