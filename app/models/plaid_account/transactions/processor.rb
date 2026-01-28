class PlaidAccount::Transactions::Processor
  def initialize(plaid_account)
    @plaid_account = plaid_account
  end

  def process
    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    modified_transactions.each do |transaction|
      PlaidEntry::Processor.new(
        transaction,
        plaid_account: plaid_account,
        category_matcher: category_matcher
      ).process
    end

    PlaidAccount.transaction do
      removed_transactions.each do |transaction|
        remove_plaid_transaction(transaction)
      end
    end
  end

  private
    attr_reader :plaid_account

    def category_matcher
      @category_matcher ||= PlaidAccount::Transactions::CategoryMatcher.new(family_categories)
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
      plaid_account.current_account
    end

    def remove_plaid_transaction(raw_transaction)
      account.entries.find_by(plaid_id: raw_transaction["transaction_id"])&.destroy
    end

    # Since we find_or_create_by transactions, we don't need a distinction between added/modified
    def modified_transactions
      modified = plaid_account.raw_transactions_payload["modified"] || []
      added = plaid_account.raw_transactions_payload["added"] || []

      transactions = modified + added

      # Filter out pending transactions based on env var or Setting
      # Priority: env var > Setting (allows runtime changes via UI)
      include_pending = if ENV["PLAID_INCLUDE_PENDING"].present?
        Rails.configuration.x.plaid.include_pending
      else
        Setting.syncs_include_pending
      end
      unless include_pending
        transactions = transactions.reject { |t| t["pending"] == true }
      end

      transactions
    end

    def removed_transactions
      plaid_account.raw_transactions_payload["removed"] || []
    end
end
