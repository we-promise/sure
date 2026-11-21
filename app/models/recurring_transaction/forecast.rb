# Projects a family's active recurring transactions over a date window, filtered
# the way Transaction::Search filters the transactions list, so the Upcoming tab
# and its summary follow the same filter bar as the list.
#
# The window runs from start_date (never before today: past occurrences are
# history, not forecast) to end_date, or DEFAULT_DAYS out when none is given.
# Filters that only describe posted transactions (tags, status, AI, attachment
# and reconcile status) have nothing to match on a series and are reported by
# #ignored_filters instead of being applied.
class RecurringTransaction::Forecast
  DEFAULT_DAYS = 10
  IGNORED_FILTERS = %w[tags status ai_status attachment_status reconcile_status].freeze

  Occurrence = Data.define(:date, :series)
  Totals = Data.define(:count, :income_money, :expense_money)

  attr_reader :family, :start_date, :end_date

  def initialize(family, user:, filters: {}, cache_version: nil)
    @family = family
    @user = user
    @filters = filters.to_h.with_indifferent_access
    @cache_version = cache_version
    @start_date = [ parse_date(@filters[:start_date]), Date.current ].compact.max
    @end_date = parse_date(@filters[:end_date]) || Date.current + DEFAULT_DAYS
  end

  # The series with at least one occurrence in the window. Only IDs are
  # cached: cached ActiveRecord objects outlive schema changes across upgrades
  # and raise MissingAttributeError for columns added since.
  def series
    @series ||= begin
      ids = Rails.cache.fetch(cache_key, expires_in: 1.day) { filtered_scope.pluck(:id) }
      ids.empty? ? [] : family.recurring_transactions.where(id: ids).includes(merchant: { logo_attachment: :blob }).to_a
    end
  end

  def occurrences
    @occurrences ||= series
      .flat_map { |s| s.projected_due_dates(through: end_date).select { |date| date >= start_date }.map { |date| Occurrence.new(date:, series: s) } }
      .sort_by(&:date)
  end

  # Transfers count as occurrences but not as income or expense, as in
  # Transaction::Search#totals. Amounts convert to the family currency at the
  # current rate; a currency with no rate is left out rather than counted at 1.
  def totals
    @totals ||= begin
      rates = ExchangeRate.rates_for(occurrences.map { |o| o.series.currency }, to: family.currency)
      income = expense = 0.to_d

      occurrences.each do |occurrence|
        series = occurrence.series
        rate = rates[series.currency]
        next if series.transfer? || rate.nil?

        amount = expected_amount(series) * rate
        amount.negative? ? income += amount.abs : expense += amount
      end

      Totals.new(
        count: occurrences.size,
        income_money: Money.new(income, family.currency),
        expense_money: Money.new(expense, family.currency)
      )
    end
  end

  def ignored_filters
    IGNORED_FILTERS.select { |key| @filters[key].present? }
  end

  private
    attr_reader :user, :filters

    def filtered_scope
      scope = family.recurring_transactions.accessible_by(user).active
        .where(next_expected_date: Date.current..end_date)

      scope = filter_accounts(scope)
      scope = filter_categories(scope)
      scope = filter_merchants(scope)
      scope = filter_types(scope)
      scope = filter_search(scope)
      filter_amount(scope)
    end

    def filter_accounts(scope)
      scope = scope.where(account_id: family.accounts.where(name: filters[:accounts]).select(:id)) if filters[:accounts].present?
      scope = scope.where(account_id: filters[:account_ids]) if filters[:account_ids].present?
      scope
    end

    # A named category also matches its subcategories, as in the list.
    def filter_categories(scope)
      return scope if filters[:categories].blank?

      names = filters[:categories] - [ Category::UNCATEGORIZED_FILTER_VALUE ]
      named = family.categories.where(name: names)
      ids = named.pluck(:id) + family.categories.where(parent_id: named.select(:id)).pluck(:id)

      if filters[:categories].include?(Category::UNCATEGORIZED_FILTER_VALUE)
        scope.where(category_id: ids).or(scope.where(category_id: nil))
      else
        scope.where(category_id: ids)
      end
    end

    def filter_merchants(scope)
      return scope if filters[:merchants].blank?

      names = filters[:merchants] - [ Merchant::NO_MERCHANT_FILTER_VALUE ]
      named = scope.where(merchant_id: Merchant.where(name: names).select(:id))

      if filters[:merchants].include?(Merchant::NO_MERCHANT_FILTER_VALUE)
        named.or(scope.where(merchant_id: nil))
      else
        named
      end
    end

    # Same buckets as the list: positive amounts are expenses, negative are
    # income, and a series into another account is a transfer.
    def filter_types(scope)
      types = Array(filters[:types]) & %w[income expense transfer]
      return scope if types.empty? || types.size == 3

      conditions = {
        "income" => "recurring_transactions.amount < 0 AND recurring_transactions.destination_account_id IS NULL",
        "expense" => "recurring_transactions.amount >= 0 AND recurring_transactions.destination_account_id IS NULL",
        "transfer" => "recurring_transactions.destination_account_id IS NOT NULL"
      }
      scope.where(types.map { |type| "(#{conditions[type]})" }.join(" OR "))
    end

    def filter_search(scope)
      return scope if filters[:search].blank?

      scope.left_joins(:merchant).where(
        "recurring_transactions.name ILIKE :search OR merchants.name ILIKE :search",
        search: "%#{ActiveRecord::Base.sanitize_sql_like(filters[:search])}%"
      )
    end

    def filter_amount(scope)
      amount = filters[:amount]
      return scope if amount.blank? || filters[:amount_operator].blank?

      case filters[:amount_operator]
      when "equal" then scope.where("ABS(ABS(recurring_transactions.amount) - ?) <= 0.01", amount.to_f.abs)
      when "less" then scope.where("ABS(recurring_transactions.amount) < ?", amount.to_f.abs)
      when "greater" then scope.where("ABS(recurring_transactions.amount) > ?", amount.to_f.abs)
      else scope
      end
    end

    # The amount a projected row shows: the running average for a manual
    # series that tracks one, otherwise the fixed amount.
    def expected_amount(series)
      series.manual? && series.expected_amount_avg.present? ? series.expected_amount_avg : series.amount
    end

    def cache_key
      applied = filters.except(*IGNORED_FILTERS, :start_date, :end_date).sort.to_h
      [
        "transactions_projected_recurring/v7", family.id, user.id, Date.current, start_date, end_date,
        Digest::SHA256.hexdigest(applied.to_json), @cache_version
      ].join("/")
    end

    def parse_date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end
end
