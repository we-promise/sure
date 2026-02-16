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

  attr_reader :family

  def initialize(family, filters: {})
    @family = family
    super(filters)
  end

  def transactions_scope
    @transactions_scope ||= begin
      # This already joins entries + accounts. To avoid expensive double-joins, don't join them again (causes full table scan)
      query = family.transactions

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

  # Computes totals for the specific search
  # Note: Excludes tax-advantaged accounts (401k, IRA, etc.) from totals calculation
  # because those transactions are retirement savings, not daily income/expenses.
  def totals
    @totals ||= begin
      Rails.cache.fetch("transaction_search_totals/#{cache_key_base}") do
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
          count: result.transactions_count.to_i,
          income_money: Money.new(result.income_total, family.currency),
          expense_money: Money.new(result.expense_total, family.currency)
        )
      end
    end
  end

  def cache_key_base
    [
      family.id,
      Digest::SHA256.hexdigest(attributes.sort.to_h.to_json), # cached by filters
      family.entries_cache_version,
      Digest::SHA256.hexdigest(family.tax_advantaged_account_ids.sort.to_json) # stable across processes
    ].join("/")
  end

  private
    Totals = Data.define(:count, :income_money, :expense_money)

    def apply_active_accounts_filter(query, active_accounts_only_filter)
      if active_accounts_only_filter
        query.where(accounts: { status: [ "draft", "active" ] })
      else
        query
      end
    end


    def apply_category_filter(query, categories)
      return query unless categories.present?

      # Check for "Uncategorized" in any supported locale (handles URL params in different languages)
      all_uncategorized_names = Category.all_uncategorized_names
      include_uncategorized = (categories & all_uncategorized_names).any?
      real_categories = categories - all_uncategorized_names

      # Get parent category IDs for the given category names
      parent_category_ids = family.categories.where(name: real_categories).pluck(:id)

      uncategorized_condition = "categories.id IS NULL AND transactions.kind NOT IN (?)"

      # Build condition based on whether parent_category_ids is empty
      if parent_category_ids.empty?
        if include_uncategorized
          query = query.left_joins(:category).where(
            "categories.name IN (?) OR (#{uncategorized_condition})",
            real_categories.presence || [], Transaction::TRANSFER_KINDS
          )
        else
          query = query.left_joins(:category).where(categories: { name: real_categories })
        end
      else
        if include_uncategorized
          query = query.left_joins(:category).where(
            "categories.name IN (?) OR categories.parent_id IN (?) OR (#{uncategorized_condition})",
            real_categories, parent_category_ids, Transaction::TRANSFER_KINDS
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

    def apply_merchant_filter(query, merchants)
      return query unless merchants.present?
      query.joins(:merchant).where(merchants: { name: merchants })
    end

    def apply_tag_filter(query, tags)
      return query unless tags.present?
      query.joins(:tags).where(tags: { name: tags })
    end

    def apply_status_filter(query, statuses)
      return query unless statuses.present?
      return query if statuses.uniq.sort == [ "confirmed", "pending" ] # Both selected = no filter

      pending_condition = <<~SQL.squish
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
      SQL

      confirmed_condition = <<~SQL.squish
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean IS DISTINCT FROM true
        AND (transactions.extra -> 'plaid' ->> 'pending')::boolean IS DISTINCT FROM true
        AND (transactions.extra -> 'lunchflow' ->> 'pending')::boolean IS DISTINCT FROM true
      SQL

      case statuses.sort
      when [ "pending" ]
        query.where(pending_condition)
      when [ "confirmed" ]
        query.where(confirmed_condition)
      else
        query
      end
    end
end
