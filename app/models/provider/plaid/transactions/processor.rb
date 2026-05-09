# Iterates added/modified/removed transactions on a Provider::Account's
# raw_transactions_payload and dispatches to EntryProcessor. Direct port of
# PlaidAccount::Transactions::Processor.
class Provider::Plaid::Transactions::Processor
  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    modified_transactions.each do |transaction|
      Provider::Plaid::Transactions::EntryProcessor.new(
        transaction,
        provider_account: provider_account,
        category_matcher: category_matcher
      ).process
    end

    Provider::Account.transaction do
      removed_transactions.each do |transaction|
        remove_plaid_transaction(transaction)
      end
    end
  end

  private
    attr_reader :provider_account

    def category_matcher
      @category_matcher ||= Provider::CategoryMatcher.new(
        family_categories,
        taxonomy: Provider::Plaid::Transactions::CategoryTaxonomy
      )
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
      provider_account.account
    end

    def remove_plaid_transaction(raw_transaction)
      account.entries.find_by(plaid_id: raw_transaction["transaction_id"])&.destroy
    end

    # find_or_create_by upserts, so added + modified are processed identically.
    def modified_transactions
      modified = provider_account.raw_transactions_payload&.dig("modified") || []
      added    = provider_account.raw_transactions_payload&.dig("added")    || []
      transactions = modified + added

      include_pending = if ENV["PLAID_INCLUDE_PENDING"].present?
        Rails.configuration.x.plaid.include_pending
      else
        Setting.syncs_include_pending
      end
      include_pending ? transactions : transactions.reject { |t| t["pending"] == true }
    end

    def removed_transactions
      provider_account.raw_transactions_payload&.dig("removed") || []
    end
end
