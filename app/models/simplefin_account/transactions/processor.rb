class SimplefinAccount::Transactions::Processor
  attr_reader :simplefin_account

  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    transactions = simplefin_account.raw_transactions_payload.to_a
    acct = simplefin_account.current_account
    acct_info = acct ? "Account id=#{acct.id} name='#{acct.name}' type=#{acct.accountable_type}" : "NO LINKED ACCOUNT"

    if transactions.empty?
      Rails.logger.info "SimplefinAccount::Transactions::Processor - No transactions in raw_transactions_payload for simplefin_account #{simplefin_account.id} (#{simplefin_account.name}) - #{acct_info}"
      return
    end

    Rails.logger.info "SimplefinAccount::Transactions::Processor - Processing #{transactions.count} transactions for simplefin_account #{simplefin_account.id} (#{simplefin_account.name}) - #{acct_info}"

    # Log first few transaction IDs for debugging
    sample_ids = transactions.first(3).map { |t| t.is_a?(Hash) ? (t[:id] || t["id"]) : nil }.compact
    Rails.logger.info "SimplefinAccount::Transactions::Processor - Sample transaction IDs: #{sample_ids.inspect}"

    processed_count = 0
    error_count = 0

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    transactions.each do |transaction_data|
      SimplefinEntry::Processor.new(
        transaction_data,
        simplefin_account: simplefin_account
      ).process
      processed_count += 1
    rescue => e
      error_count += 1
      tx_id = transaction_data.is_a?(Hash) ? (transaction_data[:id] || transaction_data["id"]) : nil
      Rails.logger.error "SimplefinAccount::Transactions::Processor - Error processing transaction #{tx_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
    end

    Rails.logger.info "SimplefinAccount::Transactions::Processor - Completed for simplefin_account #{simplefin_account.id}: #{processed_count} processed, #{error_count} errors"
  end

  private

    def category_matcher
      @category_matcher ||= SimplefinAccount::Transactions::CategoryMatcher.new(family_categories)
    end

    def family_categories
      @family_categories ||= begin
        if account.family.categories.none?
          account.family.categories.bootstrap!
        end

        account.family.categories
      end
    end

    def account
      simplefin_account.current_account
    end
end
