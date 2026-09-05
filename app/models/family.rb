class Family < ApplicationRecord
  include Syncable, AutoTransferMatchable, Subscribeable, VectorSearchable
  include PlaidConnectable, SimplefinConnectable, LunchflowConnectable, AkahuConnectable, EnableBankingConnectable
  include CoinbaseConnectable, BinanceConnectable, KrakenConnectable, CoinstatsConnectable, SnaptradeConnectable, MercuryConnectable, BrexConnectable, SophtronConnectable
  include IndexaCapitalConnectable, IbkrConnectable, WiseConnectable
  include UpConnectable
  include Trading212Connectable
  include TradeRepublicConnectable
  include QuestradeConnectable
  include RedbarkConnectable
  include OnchainWalletConnectable

  DATE_FORMATS = [
    [ "MM-DD-YYYY", "%m-%d-%Y" ],
    [ "DD.MM.YYYY", "%d.%m.%Y" ],
    [ "DD-MM-YYYY", "%d-%m-%Y" ],
    [ "YYYY-MM-DD", "%Y-%m-%d" ],
    [ "DD/MM/YYYY", "%d/%m/%Y" ],
    [ "YYYY/MM/DD", "%Y/%m/%d" ],
    [ "MM/DD/YYYY", "%m/%d/%Y" ],
    [ "D/MM/YYYY", "%e/%m/%Y" ],
    [ "YYYY.MM.DD", "%Y.%m.%d" ],
    [ "YYYYMMDD", "%Y%m%d" ],
    # QIF month-name imports rely on QifParser preserving normalized spaces.
    [ "DD MMM YYYY", "%d %b %Y" ]
  ].freeze


  MONIKERS = [ "Family", "Group" ].freeze
  ASSISTANT_TYPES = %w[builtin external].freeze
  SHARING_DEFAULTS = %w[shared private].freeze

  has_many :users, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy

  has_many :imports, dependent: :destroy
  has_many :import_sessions, dependent: :destroy
  has_many :import_source_mappings, dependent: :destroy
  has_many :family_exports, dependent: :destroy
  has_many :account_statements, dependent: :destroy

  has_many :entries, through: :accounts
  has_many :transactions, through: :accounts
  has_many :rules, dependent: :destroy
  has_many :trades, through: :accounts
  has_many :holdings, through: :accounts

  has_many :tags, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :merchants, dependent: :destroy, class_name: "FamilyMerchant"

  has_many :budgets, dependent: :destroy
  has_many :budget_categories, through: :budgets

  has_many :goals, dependent: :destroy

  # Net inflow into every depository account linked to any primary-currency
  # goal, over the given window. Transfers between linked accounts net to zero
  # because both sides of an internal move land inside the same account set;
  # external transfers (e.g. checking → linked savings) net positive.
  #
  # Scoped to the family's primary currency: mixed-currency families would
  # otherwise sum raw EUR + USD numbers and surface the result as primary.
  # Foreign-currency goals are excluded from this KPI until FX conversion is
  # added.
  #
  # Entry amount convention in Sure: inflow is negative, so flip the sign.
  # Result is allowed to go negative (net outflow last 30d) so the headline
  # reflects reality; the controller decides how to render.
  def savings_inflow_velocity(range: 30.days.ago.to_date..Date.current, account_ids: nil)
    ids = account_ids || goal_linked_account_ids
    return 0 if ids.empty?

    net = Entry
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(account_id: ids, date: range)
      .where(excluded: false)
      .merge(Transaction.excluding_pending)
      .sum(:amount)

    -net.to_d
  end

  # Two velocity windows in a single pair of sums that share one
  # account-id lookup. The kpi tile on the index reads both the current
  # 30d window and the prior 30d window; without this helper the
  # `accounts.joins(:goal_accounts)…pluck(:id)` query runs twice per
  # request even though the answer is identical.
  def savings_inflow_windows(window_days: 30, now: Date.current)
    ids = goal_linked_account_ids
    {
      current: savings_inflow_velocity(range: (now - window_days)..now, account_ids: ids),
      prior:   savings_inflow_velocity(range: (now - 2 * window_days)..(now - window_days - 1), account_ids: ids)
    }
  end

  private

    # Depository accounts linked to this family's goals, restricted to the
    # primary currency until FX is added. Memoized for the lifetime of the
    # Family instance so a single request that reads velocity twice (the
    # KPI tile uses current vs prior 30d) doesn't re-run the join+pluck.
    # `accounts` is already scoped by the has_many association, and the
    # join restricts to this family's goals — so cross-family bleed
    # remains impossible.
    def goal_linked_account_ids
      @goal_linked_account_ids ||= accounts
        .joins(:goal_accounts)
        .where(goal_accounts: { goal_id: goals.select(:id) })
        .where(currency: primary_currency_code)
        .distinct
        .pluck(:id)
    end

  public

  has_many :llm_usages, dependent: :destroy
  has_many :recurring_transactions, dependent: :destroy
  has_many :recurring_occurrences, dependent: :destroy
  has_many :insights, dependent: :destroy

  # Families with at least one opted-in member. Lets a job filter in one
  # indexed query rather than loading every family and asking each in Ruby.
  scope :with_preview_features, -> { where(id: User.with_preview_features.select(:family_id)) }

  # Family-level rollup of the per-user preview flag, for callers that run
  # without a Current.user (the nightly insights job). Preview access is a
  # personal preference but the data it produces is family-scoped, so one
  # opted-in member is enough to generate for the family.
  #
  # EXISTS rather than `users.any?(&:preview_features_enabled?)`: the job asks
  # this once per family, and the block form would load and instantiate every
  # member just to answer a boolean.
  #
  # Never gate UI on this — visibility is per-user, and this answers "somebody
  # in the household opted in", so a view using it would show the feature to a
  # user who explicitly opted out. Use the PreviewGateable helper (Current.user)
  # for anything a person sees.
  def preview_features_enabled?
    users.with_preview_features.exists?
  end

  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }
  validates :date_format, inclusion: { in: DATE_FORMATS.map(&:last) }
  validates :month_start_day, inclusion: { in: 1..28 }
  validates :moniker, inclusion: { in: MONIKERS }
  validates :assistant_type, inclusion: { in: ASSISTANT_TYPES }
  validates :default_account_sharing, inclusion: { in: SHARING_DEFAULTS }
  validates :personal_budgets, inclusion: { in: [ true, false ] }
  validates :household_budget_enabled, inclusion: { in: [ true, false ] }
  validate :timezone_must_be_a_known_zone, if: :timezone_changed?

  before_validation :normalize_enabled_currencies!

  def primary_currency_code
    self.class.normalize_currency_code(currency) || "USD"
  end

  def default_currency_for_country
    self.class.default_currency_for_country(country)
  end

  def self.default_currency_for_country(country)
    country_currency = ISO3166::Country.new(country.to_s.upcase)&.currency_code
    normalize_currency_code(country_currency) || "USD"
  end

  def self.default_currency_by_country
    LanguagesHelper::COUNTRY_MAPPING.keys.index_with { |country| default_currency_for_country(country) }
  end

  def self.normalize_currency_code(value)
    return if value.blank?

    Money::Currency.new(value).iso_code
  rescue Money::Currency::UnknownCurrencyError, ArgumentError
    nil
  end

  # Callers should still enqueue the normal family sync immediately. Plaid's
  # refresh is asynchronous, and its polling chain schedules a distinct item
  # sync after the cursor advances (or after the bounded polling fallback), so
  # fresh transactions are imported even if the baseline family sync runs first.
  def request_plaid_transactions_refreshes_later(source:)
    enqueued_job = PlaidTransactionsRefreshAllJob.perform_later(self, source: source)
    return enqueued_job if enqueued_job

    capture_plaid_refresh_enqueue_failure(source:, error_class: "ActiveJob::EnqueueError")
    nil
  rescue => error
    capture_plaid_refresh_enqueue_failure(source:, error_class: error.class.name)
    nil
  end

  def custom_enabled_currencies?
    enabled_currencies.present?
  end

  def enabled_currency_codes(extra: [])
    selected_codes = if custom_enabled_currencies?
      [ primary_currency_code, *Array(enabled_currencies) ]
    else
      Money::Currency.as_options.map(&:iso_code)
    end

    normalize_currency_codes([ *selected_codes, *Array(extra) ])
  end

  def enabled_currency_objects(extra: [])
    enabled_currency_codes(extra:).map { |code| Money::Currency.new(code) }
  end

  def secondary_enabled_currency_objects(extra: [])
    enabled_currency_objects(extra:).reject { |currency| currency.iso_code == primary_currency_code }
  end

  def capture_plaid_refresh_enqueue_failure(source:, error_class:)
    DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: "Plaid transaction refresh could not be enqueued; continuing with normal sync",
      source: source,
      provider_key: "plaid",
      family: self,
      metadata: { error_class: error_class }
    )
  rescue => logging_error
    Rails.logger.warn(
      "Plaid refresh enqueue diagnostic failed: #{logging_error.class.name}"
    )
  end
  private :capture_plaid_refresh_enqueue_failure


  def moniker_label
    case moniker.presence
    when nil, "Family"
      I18n.t("shared.family_moniker.singular", default: "Family")
    when "Group"
      I18n.t("shared.family_moniker.group_singular", default: "Group")
    else
      moniker
    end
  end

  def moniker_label_plural
    case moniker.presence
    when nil, "Family"
      I18n.t("shared.family_moniker.plural", default: "Families")
    when "Group"
      I18n.t("shared.family_moniker.group_plural", default: "Groups")
    else
      "#{moniker}s"
    end
  end

  def share_all_by_default?
    default_account_sharing == "shared"
  end

  # Shares every existing account in this family (except ones the user already
  # owns) with the given user, honoring the family's default sharing policy and
  # the user's role. Guests receive read_only; members/admins receive read_write.
  #
  # This is the single entry point for "a member just joined, give them the
  # accounts the family shares by default." It self-guards on the sharing policy
  # and family membership so every membership path (invitation accept, SSO JIT
  # sign-up, token registration, mobile SSO) can call it without reintroducing
  # the "member joined but sees nothing" bug. No-op when sharing is disabled or
  # there is nothing to share, and idempotent on re-run.
  def auto_share_existing_accounts_with(user)
    return unless share_all_by_default?
    # Load-bearing security guard: insert_all below bypasses AccountShare's
    # user_in_same_family / cannot_share_with_owner validations, so this
    # membership check is the ONLY thing preventing cross-family sharing.
    # Do not drop it when refactoring.
    return unless user&.persisted? && user.family_id == id

    permission = user.guest? ? "read_only" : "read_write"
    records = accounts.where.not(owner_id: user.id).pluck(:id).map do |account_id|
      { account_id: account_id, user_id: user.id, permission: permission,
        include_in_finances: true, created_at: Time.current, updated_at: Time.current }
    end

    AccountShare.insert_all(records, unique_by: %i[account_id user_id]) if records.any?
  end

  def uses_custom_month_start?
    month_start_day != 1
  end

  def custom_month_start_for(date)
    if date.day >= month_start_day
      Date.new(date.year, date.month, month_start_day)
    else
      previous_month = date - 1.month
      Date.new(previous_month.year, previous_month.month, month_start_day)
    end
  end

  def custom_month_end_for(date)
    start_date = custom_month_start_for(date)
    next_month_start = start_date + 1.month
    next_month_start - 1.day
  end

  def current_custom_month_period
    start_date = custom_month_start_for(Date.current)
    end_date = custom_month_end_for(Date.current)
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def assigned_merchants
    merchant_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    Merchant.where(id: merchant_ids)
  end

  def available_merchants
    assigned_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: self)
      .recently_unlinked
      .pluck(:merchant_id)
    family_merchant_ids = merchants.pluck(:id)
    Merchant.where(id: (assigned_ids + recently_unlinked_ids + family_merchant_ids).uniq)
  end

  # Merchant names already associated with this family (via any provider, or a
  # manually created FamilyMerchant) -- used to recognize a merchant embedded in
  # noisy provider text (e.g. Enable Banking's remittance lines) without
  # inventing a new one from scratch. Deliberately excludes recently-unlinked
  # merchants (unlike available_merchants), since those were explicitly removed.
  def known_merchant_names
    (assigned_merchants.pluck(:name) + merchants.pluck(:name)).uniq
  end

  def assigned_merchants_for(user)
    merchant_ids = Transaction.joins(:entry)
      .where(entries: { account_id: accounts.accessible_by(user).select(:id) })
      .where.not(merchant_id: nil)
      .distinct
      .pluck(:merchant_id)
    Merchant.where(id: merchant_ids)
  end

  def available_merchants_for(user)
    assigned_ids = Transaction.joins(:entry)
      .where(entries: { account_id: accounts.accessible_by(user).select(:id) })
      .where.not(merchant_id: nil)
      .distinct
      .pluck(:merchant_id)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: self)
      .recently_unlinked
      .pluck(:merchant_id)
    family_merchant_ids = merchants.pluck(:id)
    Merchant.where(id: (assigned_ids + recently_unlinked_ids + family_merchant_ids).uniq)
  end

  def auto_categorize_transactions_later(transactions, rule_run_id: nil)
    AutoCategorizeJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  def auto_categorize_transactions(transaction_ids)
    AutoCategorizer.new(self, transaction_ids: transaction_ids).auto_categorize
  end

  def auto_detect_transaction_merchants_later(transactions, rule_run_id: nil)
    AutoDetectMerchantsJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  def auto_detect_transaction_merchants(transaction_ids)
    AutoMerchantDetector.new(self, transaction_ids: transaction_ids).auto_detect
  end

  # Memoized per user: the layout renders the account sidebar on every page
  # (mobile + desktop, each with 3 tabs), so a single request can ask for the
  # balance sheet many times. Rebuilding it repeats the account/sync/exchange-
  # rate queries it depends on.
  def balance_sheet(user: Current.user)
    @balance_sheets ||= {}
    @balance_sheets[user&.id] ||= BalanceSheet.new(self, user: user)
  end

  def income_statement(user: Current.user, accounts: nil)
    IncomeStatement.new(self, user: user, accounts: accounts)
  end

  # Returns the Investment Contributions category for this family, creating it if it doesn't exist.
  # This is used for auto-categorizing transfers to investment accounts.
  # Always uses the family's locale to ensure consistent category naming across all users.
  def investment_contributions_category
    # Find ALL legacy categories (created under old request-locale behavior)
    legacy = categories.where(name: Category.all_investment_contributions_names).order(:created_at).to_a

    if legacy.any?
      keeper = legacy.first
      duplicates = legacy[1..]

      # Reassign transactions and subcategories from duplicates to keeper
      if duplicates.any?
        duplicate_ids = duplicates.map(&:id)
        categories.where(parent_id: duplicate_ids).update_all(parent_id: keeper.id)
        Transaction.where(category_id: duplicate_ids).update_all(category_id: keeper.id)
        BudgetCategory.where(category_id: duplicate_ids).update_all(category_id: keeper.id)
        categories.where(id: duplicate_ids).delete_all
      end

      # Rename keeper to family's locale name if needed
      I18n.with_locale(locale) do
        correct_name = Category.investment_contributions_name
        keeper.update!(name: correct_name) unless keeper.name == correct_name
      end
      return keeper
    end

    # Create new category using family's locale
    I18n.with_locale(locale) do
      categories.find_or_create_by!(name: Category.investment_contributions_name) do |cat|
        cat.color = "#0d9488"
        cat.lucide_icon = "trending-up"
      end
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Handle race condition: another process created the category
    I18n.with_locale(locale) do
      categories.find_by!(name: Category.investment_contributions_name)
    end
  end

  # Returns account IDs for tax-advantaged accounts (401k, IRA, HSA, etc.)
  # Used to exclude these accounts from budget/cashflow calculations.
  # Tax-advantaged accounts are retirement savings, not daily expenses.
  def tax_advantaged_account_ids
    @tax_advantaged_account_ids ||= begin
      # Investment accounts derive tax_treatment from subtype
      tax_advantaged_subtypes = Investment::SUBTYPES.select do |_, meta|
        meta[:tax_treatment].in?(%i[tax_deferred tax_exempt tax_advantaged])
      end.keys

      investment_ids = accounts
        .joins("INNER JOIN investments ON investments.id = accounts.accountable_id AND accounts.accountable_type = 'Investment'")
        .where(investments: { subtype: tax_advantaged_subtypes })
        .pluck(:id)

      # Crypto accounts have an explicit tax_treatment column
      crypto_ids = accounts
        .joins("INNER JOIN cryptos ON cryptos.id = accounts.accountable_id AND accounts.accountable_type = 'Crypto'")
        .where(cryptos: { tax_treatment: %w[tax_deferred tax_exempt] })
        .pluck(:id)

      investment_ids + crypto_ids + tax_advantaged_depository_account_ids
    end
  end

  # Memoized per user for the same reason as #balance_sheet above.
  def investment_statement(user: Current.user)
    @investment_statements ||= {}
    @investment_statements[user&.id] ||= InvestmentStatement.new(self, user: user)
  end

  def eu?
    country != "US" && country != "CA"
  end

  def requires_securities_data_provider?
    # If family has any trades, they need a provider for historical prices
    trades.any?
  end

  def requires_exchange_rates_data_provider?
    # If family has any accounts not denominated in the family's currency, they need a provider for historical exchange rates
    return true if accounts.where.not(currency: self.currency).any?

    # If family has any entries in different currencies, they need a provider for historical exchange rates
    uniq_currencies = entries.pluck(:currency).uniq
    return true if uniq_currencies.count > 1
    return true if uniq_currencies.count > 0 && uniq_currencies.first != self.currency

    false
  end

  def missing_data_provider?
    (requires_securities_data_provider? && Security.provider.nil?) ||
    (requires_exchange_rates_data_provider? && ExchangeRate.provider.nil?)
  end

  # Returns securities with plan restrictions for a specific provider
  # @param provider [String] The provider name (e.g., "TwelveData")
  # @return [Array<Hash>] Array of hashes with ticker, name, required_plan, provider
  def securities_with_plan_restrictions(provider:)
    security_ids = trades.joins(:security).pluck("securities.id").uniq
    return [] if security_ids.empty?

    restrictions = Security.plan_restrictions_for(security_ids, provider: provider)
    return [] if restrictions.empty?

    Security.where(id: restrictions.keys).map do |security|
      restriction = restrictions[security.id]
      {
        ticker: security.ticker,
        name: security.name,
        required_plan: restriction[:required_plan],
        provider: restriction[:provider]
      }
    end
  end

  def oldest_entry_date
    entries.order(:date).first&.date || Date.current
  end

  # Used for invalidating family / balance sheet related aggregation queries
  def build_cache_key(key, invalidate_on_data_updates: false)
    # Our data sync process updates this timestamp whenever any family account successfully completes a data update.
    # By including it in the cache key, we can expire caches every time family account data changes.
    data_invalidation_key = invalidate_on_data_updates ? latest_sync_completed_at : nil

    [
      id,
      key,
      data_invalidation_key,
      accounts.maximum(:updated_at)
    ].compact.join("_")
  end

  # Used for invalidating entry related aggregation queries
  def entries_cache_version
    "#{entries.count}-#{entries.maximum(:updated_at)&.to_f || 0}"
  end

  # Used for invalidating caches keyed on entries (e.g. the transactions
  # index's uncategorized count). Unlike #entries_cache_version, includes
  # .count so a hard-deleted entry busts the cache even when it didn't hold
  # the current max updated_at, and uses full-precision timestamps so two
  # updates within the same second still produce distinct versions.
  def entries_version
    "#{entries.count}-#{entries.maximum(:updated_at)&.to_f}"
  end

  # Used for invalidating caches keyed on recurring transactions (e.g. the
  # transactions index's projected recurring list). See #entries_version for
  # why .count is included alongside the timestamp.
  def recurring_transactions_version
    "#{recurring_transactions.count}-#{recurring_transactions.maximum(:updated_at)&.to_f}"
  end

  # Used for invalidating caches whose results depend on which accounts are
  # active/draft vs. disabled (e.g. AccountsController#toggle_active changes
  # nothing on entries, but changes which entries `uncategorized_transactions`
  # considers accessible).
  def accounts_status_version
    "#{accounts.count}-#{accounts.maximum(:updated_at)&.to_f}"
  end

  # Used for invalidating caches that render merchant name/logo for recurring
  # transactions (e.g. the transactions index's projected recurring list).
  # Recurring detection copies `transaction.merchant_id` (see
  # RecurringTransaction::Identifier), which can point at either a
  # family-owned FamilyMerchant or a shared ProviderMerchant -- editing either
  # (e.g. a manual rename, or ProviderMerchant::Enhancer updating a shared
  # provider merchant's name/logo) doesn't touch `recurring_transactions`.
  # Scoped to only the merchants actually referenced by this family's
  # recurring transactions, rather than all family merchants, so unrelated
  # merchant edits don't bust the cache unnecessarily.
  def recurring_transaction_merchants_version
    merchant_ids = recurring_transactions.where.not(merchant_id: nil).distinct.pluck(:merchant_id)
    return "0-" if merchant_ids.empty?

    scope = Merchant.where(id: merchant_ids)
    "#{scope.count}-#{scope.maximum(:updated_at)&.to_f}"
  end

  def self_hoster?
    Rails.application.config.app_mode.self_hosted?
  end

  # Lazy so existing families get a token on first render, and resetting is
  # revocation.
  def bills_feed_token!
    return bills_feed_token if bills_feed_token.present?

    update!(bills_feed_token: SecureRandom.urlsafe_base64(24))
    bills_feed_token
  end

  def reset_bills_feed_token!
    update!(bills_feed_token: SecureRandom.urlsafe_base64(24))
    bills_feed_token
  end

  # The URL a member subscribes to carries the MEMBER's identity, because the
  # feed must honor per-account sharing: a member who can reach a subset of
  # accounts must not receive the whole family's obligations. The family
  # secret never appears in the URL; only a digest of it does, so rotating
  # `bills_feed_token` still revokes every previously shared URL at once.
  def bills_feed_token_for(user)
    self.class.bills_feed_verifier.generate([ user.id, bills_feed_stamp! ])
  end

  def bills_feed_stamp!
    Digest::SHA256.hexdigest(bills_feed_token!).first(16)
  end

  # Non-minting read for the verification side: a family that never rendered
  # a feed link has no token, and a signed URL from some earlier life must
  # not conjure one into existence to match against.
  def bills_feed_stamp
    return nil if bills_feed_token.blank?

    Digest::SHA256.hexdigest(bills_feed_token).first(16)
  end

  def self.bills_feed_verifier
    Rails.application.message_verifier("bills-user-feed")
  end

  private
    # Mirrors the inline `investment_ids` / `crypto_ids` SQL blocks in
    # `tax_advantaged_account_ids`. Joins `depositories` and filters by
    # `Depository::TAX_ADVANTAGED_SUBTYPES` (currently `%w[hsa]`). Extracted
    # rather than inlined because the existing two blocks are already long
    # enough; the extraction keeps `tax_advantaged_account_ids` readable.
    def tax_advantaged_depository_account_ids
      accounts
        .joins("INNER JOIN depositories ON depositories.id = accounts.accountable_id AND accounts.accountable_type = 'Depository'")
        .where(depositories: { subtype: Depository::TAX_ADVANTAGED_SUBTYPES })
        .pluck(:id)
    end

    def normalize_enabled_currencies!
      if enabled_currencies.blank?
        self.enabled_currencies = nil
        return
      end

      normalized_codes = normalize_currency_codes([ primary_currency_code, *Array(enabled_currencies) ])
      all_codes = Money::Currency.as_options.map(&:iso_code)
      all_selected = normalized_codes.size == all_codes.size && (normalized_codes - all_codes).empty?
      self.enabled_currencies = all_selected ? nil : normalized_codes
    end

    def normalize_currency_codes(values)
      Array(values).filter_map { |value| self.class.normalize_currency_code(value) }.uniq
    end

    # Not a plain `inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }`
    # on purpose: the settings form submits `tz.tzinfo.identifier` (e.g.
    # "America/New_York"), not `tz.name` (e.g. "Eastern Time (US & Canada)")
    # -- see LanguagesHelper#timezone_options. For every zone Rails ships,
    # those two differ, so an inclusion check against `.name` would reject
    # every legitimate value the form actually submits. `ActiveSupport::TimeZone[]`
    # resolves both forms, and is the same lookup `Localize#resolved_timezone`
    # uses at request time, so "valid at save time" and "valid when rendering"
    # can't drift apart.
    #
    # Only runs when timezone is actually being changed (see the `if:` on the
    # `validate` call above). A family that already has a stale value from
    # before this validation existed (the exact case in #390) must still be
    # able to save unrelated changes -- e.g. a settings update, or any
    # background job touching the record -- without being blocked by a field
    # nobody is currently trying to set. That value still can't crash a
    # request either way, since Localize#resolved_timezone falls back safely
    # regardless of whether this validation ever ran.
    def timezone_must_be_a_known_zone
      return if timezone.blank?

      errors.add(:timezone, :invalid) if ActiveSupport::TimeZone[timezone].blank?
    end
end
