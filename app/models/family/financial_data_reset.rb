class Family::FinancialDataReset
  ConfirmationRequiredError = Class.new(StandardError)

  CONFIRMATION_PHRASE = "RESET FINANCIAL DATA"

  COUNT_KEYS = %i[
    account_statements
    family_exports
    imports
    import_sessions
    import_source_mappings
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
  STATUS_COUNT_KEYS = (COUNT_KEYS - %i[syncs]) + %i[plaid_items]
  PROVIDER_ITEM_ASSOCIATIONS = %i[
    binance_items
    brex_items
    coinbase_items
    coinstats_items
    enable_banking_items
    ibkr_items
    indexa_capital_items
    kraken_items
    lunchflow_items
    mercury_items
    plaid_items
    simplefin_items
    snaptrade_items
    sophtron_items
    up_items
  ].freeze

  Result = Struct.new(:user, :family, :dry_run, :before_counts, :deleted_counts, :after_counts, keyword_init: true)

  class << self
    def provider_item_associations
      PROVIDER_ITEM_ASSOCIATIONS.select do |association_name|
        association = Family.reflect_on_association(association_name)

        association&.klass&.included_modules&.include?(Syncable)
      rescue NameError
        false
      end
    end
  end

  attr_reader :user, :family

  def initialize(user: nil, family: nil, dry_run: true, confirmed: false)
    if user && family && user.family != family
      raise ArgumentError, "user and family must belong to the same family"
    end

    @user = user
    @family = family || user&.family
    @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmed = ActiveModel::Type::Boolean.new.cast(confirmed)

    raise ArgumentError, "user or family is required" unless @family
  end

  def call
    before_counts = counts
    if destructive_without_confirmation?
      raise ConfirmationRequiredError, "Pass confirmed: true to Family::FinancialDataReset to delete financial data."
    end

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
      scope(:syncs).delete_all
      delete_active_storage_attachments!
      scope(:transfers).destroy_all
      scope(:rejected_transfers).destroy_all
      scope(:import_source_mappings).destroy_all
      scope(:import_mappings).destroy_all
      scope(:import_rows).destroy_all
      scope(:rule_runs).destroy_all
      scope(:rule_actions).destroy_all
      scope(:rule_conditions).destroy_all
      scope(:budget_categories).destroy_all
      scope(:taggings).destroy_all
      scope(:family_merchant_associations).delete_all
      scope(:account_statements).destroy_all
      scope(:family_exports).destroy_all
      scope(:imports).destroy_all
      scope(:import_sessions).destroy_all
      scope(:entries).destroy_all
      scope(:holdings).destroy_all
      scope(:balances).destroy_all
      scope(:account_shares).destroy_all
      scope(:account_providers).destroy_all
      scope(:recurring_transactions).destroy_all
      scope(:rules).destroy_all
      scope(:budgets).destroy_all
      scope(:categories).destroy_all
      scope(:pockets).delete_all
      scope(:tags).destroy_all
      scope(:merchants).destroy_all
      delete_provider_items!
      scope(:accounts).destroy_all
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

    def delete_provider_items!
      provider_item_associations.each do |association|
        reflection = family.class.reflect_on_association(association)
        item_class = reflection&.klass
        next unless item_class

        item_scope = provider_item_scope(association)
        item_ids = item_scope.select(:id)
        Sync.for_family(family).where(syncable_type: item_class.name, syncable_id: item_ids).delete_all

        item_class.reflect_on_all_associations(:has_many).each do |reflection|
          next if reflection.options[:through].present?
          next unless reflection.name.to_s.end_with?("_accounts")

          provider_accounts_scope = reflection.klass.where(reflection.foreign_key => item_ids)
          provider_account_ids = provider_accounts_scope.select(:id)
          legacy_account_column = legacy_account_provider_column(reflection.klass)
          if legacy_account_column
            scope(:accounts)
              .where(legacy_account_column => provider_account_ids)
              .update_all(legacy_account_column => nil)
          end
          AccountProvider.where(
            account_id: account_ids,
            provider_type: reflection.klass.name,
            provider_id: provider_account_ids
          ).delete_all
          provider_accounts_scope.delete_all
        end

        item_scope.destroy_all
      end
    end

    def counts
      COUNT_KEYS.index_with do |key|
        case key
        when :provider_items
          provider_item_associations.sum { |association| provider_item_scope(association).count }
        when :active_storage_attachments
          active_storage_attachments_count
        else
          scope(key).count
        end
      end
    end

    def deleted_counts(before_counts, after_counts)
      COUNT_KEYS.index_with { |key| before_counts.fetch(key, 0) - after_counts.fetch(key, 0) }
    end

    def provider_item_associations
      self.class.provider_item_associations.select { |association| family.respond_to?(association) }
    end

    def scope(key)
      scope_relations.fetch(key)
    end

    def scope_relations
      @scope_relations ||= begin
        account_scope = Account.where(family_id: family.id)
        account_ids = account_scope.select(:id)
        import_scope = Import.where(family_id: family.id)
        import_session_scope = ImportSession.where(family_id: family.id)
        import_ids = import_scope.select(:id)
        rule_scope = Rule.where(family_id: family.id)
        rule_ids = rule_scope.select(:id)
        budget_scope = Budget.where(family_id: family.id)
        budget_ids = budget_scope.select(:id)
        transaction_scope = Transaction.joins(:entry).where(entries: { account_id: account_ids })
        transaction_ids = transaction_scope.select(:id)
        tag_scope = Tag.where(family_id: family.id)

        {
          account_statements: AccountStatement.where(family_id: family.id),
          family_exports: FamilyExport.where(family_id: family.id),
          imports: import_scope,
          import_sessions: import_session_scope,
          import_source_mappings: ImportSourceMapping.where(family_id: family.id),
          import_rows: Import::Row.where(import_id: import_ids),
          import_mappings: Import::Mapping.where(import_id: import_ids),
          accounts: account_scope,
          account_shares: AccountShare.where(account_id: account_ids),
          account_providers: AccountProvider.where(account_id: account_ids),
          entries: Entry.where(account_id: account_ids),
          transactions: transaction_scope,
          transfers: Transfer.where(inflow_transaction_id: transaction_ids)
                             .or(Transfer.where(outflow_transaction_id: transaction_ids)),
          rejected_transfers: RejectedTransfer.where(inflow_transaction_id: transaction_ids)
                                             .or(RejectedTransfer.where(outflow_transaction_id: transaction_ids)),
          valuations: Valuation.joins(:entry).where(entries: { account_id: account_ids }),
          trades: Trade.joins(:entry).where(entries: { account_id: account_ids }),
          holdings: Holding.where(account_id: account_ids),
          balances: Balance.where(account_id: account_ids),
          recurring_transactions: RecurringTransaction.where(family_id: family.id),
          rules: rule_scope,
          rule_actions: Rule::Action.where(rule_id: rule_ids),
          rule_conditions: Rule::Condition.where(rule_id: rule_ids),
          rule_runs: RuleRun.where(rule_id: rule_ids),
          budgets: budget_scope,
          budget_categories: BudgetCategory.where(budget_id: budget_ids),
          categories: Category.where(family_id: family.id),
          tags: tag_scope,
          pockets: Pocket.where(account_id: account_ids),
          taggings: Tagging.where(tag_id: tag_scope.select(:id)),
          merchants: FamilyMerchant.where(family_id: family.id),
          family_merchant_associations: FamilyMerchantAssociation.where(family_id: family.id),
          syncs: Sync.for_family(family)
        }
      end
    end

    def account_ids
      scope(:accounts).select(:id)
    end

    def active_storage_attachments_count
      active_storage_attachment_scopes.sum(&:count)
    end

    def active_storage_attachment_scopes
      scopes = [
        attachment_scope(Account, account_ids),
        attachment_scope(AccountStatement, scope(:account_statements).select(:id)),
        attachment_scope(FamilyExport, scope(:family_exports).select(:id)),
        attachment_scope(Import, scope(:imports).select(:id)),
        attachment_scope(Transaction, scope(:transactions).select(:id))
      ]

      provider_item_associations.filter_map do |association|
        reflection = family.class.reflect_on_association(association)
        attachment_scope(reflection.klass, provider_item_scope(association).select(:id)) if reflection&.klass
      end + scopes
    end

    def attachment_scope(record_class, record_ids)
      ActiveStorage::Attachment.where(record_type: record_class.name, record_id: record_ids)
    end

    def provider_item_scope(association)
      item_class = family.class.reflect_on_association(association)&.klass
      return family.public_send(association).none unless item_class

      if item_class.column_names.include?("family_id")
        item_class.where(family_id: family.id)
      else
        family.public_send(association)
      end
    end

    def legacy_account_provider_column(provider_account_class)
      column_name = "#{provider_account_class.model_name.singular}_id"
      column_name if Account.column_names.include?(column_name)
    end
end
