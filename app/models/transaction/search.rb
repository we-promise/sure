class Transaction::Search
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :search, :string
  attribute :amount, :string
  attribute :amount_operator, :string
  attribute :types, array: true
  attribute :status, array: true
  attribute :accounts, array: true
  attribute :account_ids, array: true
  attribute :start_date, :string
  attribute :end_date, :string
  attribute :categories, array: true
  attribute :merchants, array: true
  attribute :tags, array: true
  attribute :active_accounts_only, :boolean, default: true

  attr_reader :family, :accessible_account_ids

  # Initialize a transaction search with optional filters and accessible accounts
  def initialize(family, filters: {}, accessible_account_ids: nil)
    @family = family
    @accessible_account_ids = accessible_account_ids
    super(filters)
  end

  # Get the filtered transactions scope based on all applied filters
  def transactions_scope
    @transactions_scope ||= begin
      # This already joins entries + accounts. To avoid expensive double-joins, don't join them again (causes full table scan)
      query = family.transactions.merge(Entry.excluding_split_parents)

      # Scope to accessible accounts when provided (including an empty array, which should yield no results)
      query = query.where(entries: { account_id: accessible_account_ids }) unless accessible_account_ids.nil?

      query = apply_active_accounts_filter(query, active_accounts_only)
      query = apply_category_filter(query, categories)
      query = apply_type_filter(query, types)
      query = apply_status_filter(query, status)
      query = apply_merchant_filter(query, merchants)
      query = apply_tag_filter(query, tags)
      query = EntrySearch.apply_search_filter(query, search)
      query = EntrySearch.apply_date_filters(query, start_date, end_date)
      query = EntrySearch.apply_amount_filter(query, amount, amount_operator)
      query = EntrySearch.apply_accounts_filter(query, accounts, account_ids)

      query
    end
  end

  # Compute totals for the specific search, excluding tax-advantaged accounts
  def totals
    @totals ||= begin
      # v3: bumped because the Uncategorized filter's exclusion set changed
      # (see #2592) -- without a version bump, a totals entry cached under
      # the old logic would keep being served (same cache_key_base) after
      # deploy, disagreeing with the (uncached) transactions_scope list
      # until entries_cache_version next changes for that family.
      Rails.cache.fetch("transaction_search_totals/v3/#{cache_key_base}") do
        scope = transactions_scope

        # Exclude tax-advantaged accounts from totals calculation
        tax_advantaged_ids = family.tax_advantaged_account_ids
        scope = scope.where.not(accounts: { id: tax_advantaged_ids }) if tax_advantaged_ids.present?

        result = scope
                  .select(
                    ActiveRecord::Base.sanitize_sql_array([
                      "COALESCE(SUM(CASE WHEN entries.amount >= 0 AND transactions.kind NOT IN (?) THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as expense_total",
                      Transaction::TRANSFER_KINDS
                    ]),
                    ActiveRecord::Base.sanitize_sql_array([
                      "COALESCE(SUM(CASE WHEN entries.amount < 0 AND transactions.kind NOT IN (?) THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as income_total",
                      Transaction::TRANSFER_KINDS
                    ]),
                    ActiveRecord::Base.sanitize_sql_array([
                      "COALESCE(SUM(CASE WHEN entries.amount < 0 AND transactions.kind IN (?) THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as transfer_inflow_total",
                      Transaction::TRANSFER_KINDS
                    ]),
                    ActiveRecord::Base.sanitize_sql_array([
                      "COALESCE(SUM(CASE WHEN entries.amount >= 0 AND transactions.kind IN (?) THEN ABS(entries.amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) as transfer_outflow_total",
                      Transaction::TRANSFER_KINDS
                    ]),
                    "COUNT(entries.id) as transactions_count"
                  )
                  .joins(
                    ActiveRecord::Base.sanitize_sql_array([
                      "LEFT JOIN exchange_rates er ON (er.date = entries.date AND er.from_currency = entries.currency AND er.to_currency = ?)",
                      family.currency
                    ])
                  )
                  .take

        Totals.new(
          count: result&.transactions_count.to_i,
          income_money: Money.new((result&.income_total || 0), family.currency),
          expense_money: Money.new((result&.expense_total || 0), family.currency),
          transfer_inflow_money: Money.new((result&.transfer_inflow_total || 0), family.currency),
          transfer_outflow_money: Money.new((result&.transfer_outflow_total || 0), family.currency)
        )
      end
    end
  end

  # Generate cache key based on search filters and family state
  def cache_key_base
    [
      family.id,
      Digest::SHA256.hexdigest(attributes.sort.to_h.to_json), # cached by filters
      family.entries_cache_version,
      Digest::SHA256.hexdigest(family.tax_advantaged_account_ids.sort.to_json), # stable across processes
      accessible_account_ids ? Digest::SHA256.hexdigest(accessible_account_ids.sort.to_json) : "all"
    ].join("/")
  end

  private
    Totals = Data.define(:count, :income_money, :expense_money, :transfer_inflow_money, :transfer_outflow_money)

    # Filter query to include only active accounts if requested
    def apply_active_accounts_filter(query, active_accounts_only_filter)
      if active_accounts_only_filter
        query.where(accounts: { status: [ "draft", "active" ] })
      else
        query
      end
    end


    # Filter transactions by category, supporting uncategorized and budget exclusions
    def apply_category_filter(query, categories)
      return query unless categories.present?

      # Check for "Uncategorized" in any supported locale (handles URL params in different languages)
      all_uncategorized_names = Category.all_uncategorized_names
      include_uncategorized = (categories & all_uncategorized_names).any?
      real_categories = categories - all_uncategorized_names

      # Get parent category IDs for the given category names
      parent_category_ids = family.categories.where(name: real_categories).pluck(:id)

      # Uncategorized bucket = rows without a category. Exclude only pure
      # transfer-like kinds (funds_movement, cc_payment) which represent transfers
      # between accounts, not uncategorized expenses/income. Preserve one_time
      # Exclude transfer kinds that the dashboard's uncategorized totals exclude
      # (funds_movement, one_time, cc_payment), but preserve loan_payment and
      # investment_contribution which are budget-tracked transfers that align with
      # the dashboard's uncategorized entries. https://github.com/we-promise/sure/issues/2592
      uncategorized_condition = "categories.id IS NULL AND transactions.kind NOT IN (?)"
      uncategorized_excluded_kinds = Transaction::BUDGET_EXCLUDED_KINDS

      # Build condition based on whether parent_category_ids is empty
      if parent_category_ids.empty?
        if include_uncategorized
          query = query.left_joins(:category).where(
            "categories.name IN (?) OR (#{uncategorized_condition})",
            real_categories.presence || [], uncategorized_excluded_kinds
          )
        else
          query = query.left_joins(:category).where(categories: { name: real_categories })
        end
      else
        if include_uncategorized
          query = query.left_joins(:category).where(
            "categories.name IN (?) OR categories.parent_id IN (?) OR (#{uncategorized_condition})",
            real_categories, parent_category_ids, uncategorized_excluded_kinds
          )
        else
          query = query.left_joins(:category).where(
            "categories.name IN (?) OR categories.parent_id IN (?)",
            real_categories, parent_category_ids
          )
        end
      end

      query
    end

    # Filter transactions by type (expense, income, or transfer)
    def apply_type_filter(query, types)
      return query unless types.present?
      return query if types.sort == [ "expense", "income", "transfer" ]

      case types.sort
      when [ "transfer" ]
        query.where(kind: Transaction::TRANSFER_KINDS)
      when [ "expense" ]
        query.where("entries.amount >= 0").where.not(kind: Transaction::TRANSFER_KINDS)
      when [ "income" ]
        query.where("entries.amount < 0").where.not(kind: Transaction::TRANSFER_KINDS)
      when [ "expense", "transfer" ]
        query.where("entries.amount >= 0 OR transactions.kind IN (?)", Transaction::TRANSFER_KINDS)
      when [ "income", "transfer" ]
        query.where("entries.amount < 0 OR transactions.kind IN (?)", Transaction::TRANSFER_KINDS)
      when [ "expense", "income" ]
        query.where.not(kind: Transaction::TRANSFER_KINDS)
      else
        query
      end
    end

    # Filter transactions by merchant name
    def apply_merchant_filter(query, merchants)
      return query unless merchants.present?
      query.joins(:merchant).where(merchants: { name: merchants })
    end

    # Filter transactions by tag name
    def apply_tag_filter(query, tags)
      return query unless tags.present?
      query.joins(:tags).where(tags: { name: tags })
    end

    # Filter transactions by status (pending or confirmed)
    def apply_status_filter(query, statuses)
      return query unless statuses.present?
      return query if statuses.uniq.sort == [ "confirmed", "pending" ] # Both selected = no filter

      # Delegate to the model scopes so the provider list stays sourced from
      # Transaction::PENDING_PROVIDERS. Previously this method hardcoded only
      # simplefin/plaid/lunchflow, silently dropping enable_banking transactions.
      case statuses.sort
      when [ "pending" ]
        query.pending
      when [ "confirmed" ]
        query.excluding_pending
      else
        query
      end
    end
end
