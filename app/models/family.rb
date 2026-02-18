class Family < ApplicationRecord
  include Syncable, AutoTransferMatchable, Subscribeable, VectorSearchable
  include PlaidConnectable, SimplefinConnectable, LunchflowConnectable, EnableBankingConnectable
  include CoinbaseConnectable, CoinstatsConnectable, SnaptradeConnectable, MercuryConnectable
  include IndexaCapitalConnectable

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
    [ "YYYYMMDD", "%Y%m%d" ]
  ].freeze


  MONIKERS = [ "Family", "Group" ].freeze
  ASSISTANT_TYPES = %w[builtin external].freeze

  has_many :users, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy

  has_many :imports, dependent: :destroy
  has_many :family_exports, dependent: :destroy

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

  has_many :llm_usages, dependent: :destroy
  has_many :recurring_transactions, dependent: :destroy

  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }
  validates :date_format, inclusion: { in: DATE_FORMATS.map(&:last) }
  validates :month_start_day, inclusion: { in: 1..28 }
  validates :moniker, inclusion: { in: MONIKERS }
  validates :assistant_type, inclusion: { in: ASSISTANT_TYPES }


  def moniker_label
    moniker.presence || "Family"
  end

  def moniker_label_plural
    moniker_label == "Group" ? "Groups" : "Families"
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

  def balance_sheet
    @balance_sheet ||= BalanceSheet.new(self)
  end

  def income_statement
    @income_statement ||= IncomeStatement.new(self)
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
        cat.classification = "expense"
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

      investment_ids + crypto_ids
    end
  end

  def investment_statement
    @investment_statement ||= InvestmentStatement.new(self)
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
    @entries_cache_version ||= begin
      ts = entries.maximum(:updated_at)
      ts.present? ? ts.to_i : 0
    end
  end

  def self_hoster?
    Rails.application.config.app_mode.self_hosted?
  end
end
