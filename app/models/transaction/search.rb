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
      query = apply_search_filter(query, search)
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
      # v4: bumped for the new counterparty_iban search predicate -- same
      # reasoning, a pre-existing cache entry doesn't know this filter exists
      # and would keep serving totals computed without it.
      Rails.cache.fetch("transaction_search_totals/v4/#{cache_key_base}") do
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

    # Transaction-specific superset of EntrySearch.apply_search_filter: also
    # matches a counterparty IBAN (or other provider-supplied account
    # identifier) stored in transactions.extra, so a user can find a payment
    # by searching the IBAN they have on a bank statement. Kept local to
    # this class rather than added to the shared EntrySearch -- that class's
    # build_query also runs against generic Entry scopes (e.g. Valuations),
    # where a bare "transactions" table reference wouldn't resolve.
    def apply_search_filter(query, search)
      return query if search.blank?

      sanitized_search = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      # The stored counterparty_iban is normalized (all non-alphanumeric
      # characters stripped, upcased) -- match that convention here too, or
      # an IBAN pasted in its common statement format ("DE89 3704 ...", or
      # with dots/dashes/a tab/newline/NBSP from a formatted PDF) would never
      # match. name/notes matching keeps the raw search term since those
      # aren't normalized.
      normalized_search = "%#{ActiveRecord::Base.sanitize_sql_like(IbanNormalizable.normalize(search).to_s)}%"

      # Targets the two counterparty keys explicitly rather than casting the
      # whole extra blob to text: that field also carries unrelated
      # provider/internal data (fx_rate, pending flags, goal pledge ids,
      # merge/match state, ...), and matching anywhere in that JSON would
      # surface transactions whose name/notes/counterparty don't actually
      # contain the search term.
      #
      # counterparty_account_id (the non-IBAN fallback identifier) is stored
      # verbatim, unlike counterparty_iban -- the processor only normalizes
      # the IBAN case (see EnableBankingEntry::Processor#counterparty_account_info),
      # so matching it against the whitespace-stripped term would miss an
      # identifier like "ACC 998877" searched with its original spacing.
      #
      # Monobank stores its own counterparty IBAN nested under its provider
      # key instead of the shared top-level counterparty_iban (see the rules
      # condition filter's identical fallback for why), so it's included
      # here too for parity -- otherwise a Monobank user could filter by
      # counterparty IBAN through Rules but not find the same transaction
      # through search. Normalized on both sides, unlike the Enable Banking
      # column: MonobankEntry::Processor stores counter_iban as-is from the
      # provider payload with no normalization step.
      query.where(
        "entries.name ILIKE :search OR entries.notes ILIKE :search " \
        "OR (transactions.extra ->> 'counterparty_iban') ILIKE :normalized_search " \
        "OR (transactions.extra ->> 'counterparty_account_id') ILIKE :search " \
        "OR UPPER(REGEXP_REPLACE(transactions.extra -> 'monobank' ->> 'counter_iban', '[^a-zA-Z0-9]', '', 'g')) ILIKE :normalized_search",
        search: sanitized_search, normalized_search: normalized_search
      )
    end

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

      include_uncategorized = categories.include?(Category::UNCATEGORIZED_FILTER_VALUE)
      real_categories = categories - [ Category::UNCATEGORIZED_FILTER_VALUE ]

      # Get parent category IDs for the given category names
      parent_category_ids = family.categories.where(name: real_categories).pluck(:id)

      # The Uncategorized bucket answers "which rows have no category", so it
      # excludes only the kinds that have nothing to categorize — the paired
      # legs of a Transfer. Shared with Entry.uncategorized_transactions so
      # this list, the uncategorized badge count and the Quick Categorize
      # wizard can't drift apart. https://github.com/we-promise/sure/issues/2592
      uncategorized_condition = "categories.id IS NULL AND transactions.kind NOT IN (?)"
      uncategorized_excluded_kinds = Transaction::UNCATEGORIZED_EXCLUDED_KINDS

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

      include_no_merchant = merchants.include?(Merchant::NO_MERCHANT_FILTER_VALUE)
      real_merchants = merchants - [ Merchant::NO_MERCHANT_FILTER_VALUE ]

      if include_no_merchant
        query.left_joins(:merchant).where("merchants.name IN (?) OR merchants.id IS NULL", real_merchants)
      else
        query.joins(:merchant).where(merchants: { name: real_merchants })
      end
    end

    # Filter transactions by tag name, matching any transaction that carries
    # at least one of the given tags.
    def apply_tag_filter(query, tags)
      return query unless tags.present?

      include_untagged = tags.include?(Tag::UNTAGGED_FILTER_VALUE)
      real_tags = tags - [ Tag::UNTAGGED_FILTER_VALUE ]

      # Use a subquery instead of an INNER/LEFT JOIN: `.joins(:tags)` fans out to
      # one row per matching tag, so a transaction tagged with two of the
      # filtered tags produces two rows and double-counts in the summary
      # box (COUNT / SUM) even though the list renders it once. A top-level
      # `.distinct` doesn't work either, since PostgreSQL rejects DISTINCT
      # combined with reverse_chronological's CASE-expression ORDER BY unless
      # that expression is also in the select list (PG::InvalidColumnReference).
      # `query` is already scoped to the current family, so the subquery
      # inherits that scoping too.
      # See https://github.com/we-promise/sure/issues/3174
      matching_ids = if include_untagged
        query.left_joins(:tags).where("tags.name IN (?) OR tags.id IS NULL", real_tags).distinct.select(:id)
      else
        query.joins(:tags).where(tags: { name: real_tags }).distinct.select(:id)
      end
      query.where(id: matching_ids)
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
