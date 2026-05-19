class Family::FinancialDataReset
  ConfirmationRequiredError = Class.new(StandardError)

  CONFIRMATION_PHRASE = "RESET FINANCIAL DATA"

  PROVIDER_ITEM_ASSOCIATIONS = %i[
    plaid_items
    simplefin_items
    lunchflow_items
    enable_banking_items
    coinbase_items
    binance_items
    kraken_items
    coinstats_items
    snaptrade_items
    mercury_items
    brex_items
    sophtron_items
    indexa_capital_items
    ibkr_items
  ].freeze

  COUNT_KEYS = %i[
    account_statements
    family_exports
    imports
    import_rows
    import_mappings
    accounts
    account_shares
    account_providers
    entries
    transactions
    transfers
    rejected_transfers
    valuations
    trades
    holdings
    balances
    recurring_transactions
    rules
    rule_actions
    rule_conditions
    rule_runs
    budgets
    budget_categories
    categories
    tags
    taggings
    merchants
    family_merchant_associations
    provider_items
    syncs
    active_storage_attachments
  ].freeze

  Result = Struct.new(:user, :family, :dry_run, :before_counts, :deleted_counts, :after_counts, keyword_init: true)

  attr_reader :user, :family

  def initialize(user: nil, family: nil, dry_run: true, confirmed: false)
    @user = user
    @family = family || user&.family
    @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmed = ActiveModel::Type::Boolean.new.cast(confirmed)

    raise ArgumentError, "user or family is required" unless @family
  end

  def call
    before_counts = counts
    raise ConfirmationRequiredError, "Set CONFIRM_RESET_FINANCIAL_DATA=yes to delete financial data." if destructive_without_confirmation?

    if dry_run?
      after_counts = before_counts
    else
      blob_ids = []
      ActiveRecord::Base.transaction do
        blob_ids = active_storage_blob_ids
        delete_financial_data!
      end
      purge_unattached_blobs(blob_ids)
      family.reload
      after_counts = counts
    end

    Result.new(
      user: user,
      family: family,
      dry_run: dry_run?,
      before_counts: before_counts,
      deleted_counts: deleted_counts(before_counts, after_counts),
      after_counts: after_counts
    )
  end

  def dry_run?
    @dry_run
  end

  private

    def destructive_without_confirmation?
      !dry_run? && !@confirmed
    end

    def delete_financial_data!
      delete_active_storage_attachments!
      family.account_statements.destroy_all
      family.family_exports.destroy_all
      family.imports.destroy_all
      family.accounts.destroy_all
      family.recurring_transactions.destroy_all
      family.rules.destroy_all
      family.budgets.destroy_all
      FamilyMerchantAssociation.where(family: family).delete_all
      family.categories.destroy_all
      family.tags.destroy_all
      family.merchants.destroy_all
      delete_provider_items_locally!
      family.syncs.destroy_all
    end

    def active_storage_blob_ids
      active_storage_attachment_scopes.flat_map do |scope|
        scope.distinct.pluck(:blob_id)
      end.uniq
    end

    def delete_active_storage_attachments!
      active_storage_attachment_scopes.each do |scope|
        scope.delete_all
      end
    end

    def purge_unattached_blobs(blob_ids)
      return if blob_ids.empty?

      ActiveStorage::Blob
        .where(id: blob_ids)
        .left_outer_joins(:attachments)
        .where(active_storage_attachments: { id: nil })
        .find_each(&:purge)
    end

    def delete_provider_items_locally!
      provider_item_associations.each do |association|
        item_class = family.class.reflect_on_association(association)&.klass
        next unless item_class

        item_ids = family.public_send(association).select(:id)
        Sync.where(syncable_type: item_class.name, syncable_id: item_ids).delete_all

        item_class.reflect_on_all_associations(:has_many).each do |reflection|
          next if reflection.options[:through].present?
          next unless reflection.name.to_s.end_with?("_accounts")

          provider_account_ids = reflection.klass.where(reflection.foreign_key => item_ids).select(:id)
          AccountProvider.where(provider_type: reflection.klass.name, provider_id: provider_account_ids).delete_all
          reflection.klass.where(reflection.foreign_key => item_ids).delete_all
        end

        family.public_send(association).delete_all
      end
    end

    def counts
      {
        account_statements: family.account_statements.count,
        family_exports: family.family_exports.count,
        imports: family.imports.count,
        import_rows: import_rows_scope.count,
        import_mappings: import_mappings_scope.count,
        accounts: family.accounts.count,
        account_shares: account_shares_scope.count,
        account_providers: account_providers_scope.count,
        entries: entries_scope.count,
        transactions: transactions_scope.count,
        transfers: transfers_scope.count,
        rejected_transfers: rejected_transfers_scope.count,
        valuations: valuations_scope.count,
        trades: trades_scope.count,
        holdings: holdings_scope.count,
        balances: balances_scope.count,
        recurring_transactions: family.recurring_transactions.count,
        rules: family.rules.count,
        rule_actions: rule_actions_scope.count,
        rule_conditions: rule_conditions_scope.count,
        rule_runs: rule_runs_scope.count,
        budgets: family.budgets.count,
        budget_categories: budget_categories_scope.count,
        categories: family.categories.count,
        tags: family.tags.count,
        taggings: taggings_scope.count,
        merchants: family.merchants.count,
        family_merchant_associations: FamilyMerchantAssociation.where(family: family).count,
        provider_items: provider_item_associations.sum { |association| family.public_send(association).count },
        syncs: syncs_count,
        active_storage_attachments: active_storage_attachments_count
      }
    end

    def deleted_counts(before_counts, after_counts)
      COUNT_KEYS.index_with { |key| before_counts.fetch(key, 0) - after_counts.fetch(key, 0) }
    end

    def provider_item_associations
      PROVIDER_ITEM_ASSOCIATIONS.select { |association| family.respond_to?(association) }
    end

    def account_ids
      family.accounts.select(:id)
    end

    def import_ids
      family.imports.select(:id)
    end

    def rule_ids
      family.rules.select(:id)
    end

    def budget_ids
      family.budgets.select(:id)
    end

    def transaction_ids
      transactions_scope.select(:id)
    end

    def entries_scope
      Entry.where(account_id: account_ids)
    end

    def transactions_scope
      Transaction.joins(:entry).where(entries: { account_id: account_ids })
    end

    def valuations_scope
      Valuation.joins(:entry).where(entries: { account_id: account_ids })
    end

    def trades_scope
      Trade.joins(:entry).where(entries: { account_id: account_ids })
    end

    def transfers_scope
      Transfer.where(inflow_transaction_id: transaction_ids).or(
        Transfer.where(outflow_transaction_id: transaction_ids)
      )
    end

    def rejected_transfers_scope
      RejectedTransfer.where(inflow_transaction_id: transaction_ids).or(
        RejectedTransfer.where(outflow_transaction_id: transaction_ids)
      )
    end

    def holdings_scope
      Holding.where(account_id: account_ids)
    end

    def balances_scope
      Balance.where(account_id: account_ids)
    end

    def account_shares_scope
      AccountShare.where(account_id: account_ids)
    end

    def account_providers_scope
      AccountProvider.where(account_id: account_ids)
    end

    def import_rows_scope
      Import::Row.where(import_id: import_ids)
    end

    def import_mappings_scope
      Import::Mapping.where(import_id: import_ids)
    end

    def rule_actions_scope
      Rule::Action.where(rule_id: rule_ids)
    end

    def rule_conditions_scope
      Rule::Condition.where(rule_id: rule_ids)
    end

    def rule_runs_scope
      RuleRun.where(rule_id: rule_ids)
    end

    def budget_categories_scope
      BudgetCategory.where(budget_id: budget_ids)
    end

    def taggings_scope
      Tagging.where(tag_id: family.tags.select(:id))
    end

    def syncs_count
      family.syncs.count + account_syncs_count + provider_item_syncs_count
    end

    def account_syncs_count
      Sync.where(syncable_type: "Account", syncable_id: account_ids).count
    end

    def provider_item_syncs_count
      provider_item_associations.sum do |association|
        reflection = family.class.reflect_on_association(association)
        next 0 unless reflection&.klass

        Sync.where(syncable_type: reflection.klass.name, syncable_id: family.public_send(association).select(:id)).count
      end
    end

    def active_storage_attachments_count
      active_storage_attachment_scopes.sum(&:count)
    end

    def active_storage_attachment_scopes
      scopes = [
        attachment_scope(Account, account_ids),
        attachment_scope(AccountStatement, family.account_statements.select(:id)),
        attachment_scope(FamilyExport, family.family_exports.select(:id)),
        attachment_scope(Import, import_ids),
        attachment_scope(Transaction, transaction_ids)
      ]

      provider_item_associations.filter_map do |association|
        reflection = family.class.reflect_on_association(association)
        attachment_scope(reflection.klass, family.public_send(association).select(:id)) if reflection&.klass
      end + scopes
    end

    def attachment_scope(record_class, record_ids)
      ActiveStorage::Attachment.where(record_type: record_class.name, record_id: record_ids)
    end
end
