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

  # The amount a projected row shows: the running average for a manual series
  # that tracks one, otherwise the fixed amount. Filters and totals use it too.
  EXPECTED_AMOUNT_SQL = "(CASE WHEN recurring_transactions.manual AND recurring_transactions.expected_amount_avg IS NOT NULL " \
                        "THEN recurring_transactions.expected_amount_avg ELSE recurring_transactions.amount END)".freeze

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

  # Stored occurrences are the schedule: a series forecasts its open ones, on
  # their effective (moved or snoozed) date, so a cycle already paid, skipped
  # or missed is not forecast again. Past the last stored occurrence the
  # schedule continues. A series with nothing stored yet falls back to its
  # cached next_expected_date, as RecurringTransaction#next_due_date does.
  def occurrences
    @occurrences ||= begin
      open = open_occurrences.group_by(&:recurring_transaction_id)
      stored_through = stored_horizons
      candidates.flat_map { |series|
        dates = if stored_through.key?(series.id)
          stored_dates(series, open.fetch(series.id, []), stored_through[series.id])
        else
          hinted_dates(series)
        end
        dates.select { |date| date.between?(start_date, end_date) }.uniq.sort.map { |date| Occurrence.new(date:, series:) }
      }.sort_by(&:date)
    end
  end

  def series
    occurrences.map(&:series).uniq
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

    # The active series matching the filters. Only IDs are cached: cached
    # ActiveRecord objects outlive schema changes across upgrades and raise
    # MissingAttributeError for columns added since.
    def candidates
      @candidates ||= begin
        ids = Rails.cache.fetch(cache_key, expires_in: 1.day) { filtered_scope.pluck(:id) }
        ids.empty? ? [] : family.recurring_transactions.where(id: ids)
                                .includes(:recurrence_rules, merchant: { logo_attachment: :blob }).to_a
      end
    end

    def stored_dates(series, open, stored_through)
      beyond = series.schedule.occurrences_between([ start_date, stored_through + 1 ].max, end_date)
      open.map(&:effective_due_on) + beyond
    end

    def hinted_dates(series)
      hint = series.next_expected_date
      first = hint <= Date.current ? hint : [ hint, series.schedule.next_occurrence_from_today ].compact.min
      [ first ] + series.schedule.occurrences_between(first + 1, end_date)
    end

    def open_occurrences
      return [] if candidates.empty?

      RecurringOccurrence.open_status.where(recurring_transaction_id: candidates.map(&:id))
        .where("GREATEST(due_on, COALESCE(snoozed_until, due_on)) BETWEEN ? AND ?", start_date, end_date).to_a
    end

    # The last stored schedule date of each candidate that has any.
    def stored_horizons
      return {} if candidates.empty?

      RecurringOccurrence.where(recurring_transaction_id: candidates.map(&:id))
        .group(:recurring_transaction_id).maximum(:original_due_on)
    end

    def filtered_scope
      scope = family.recurring_transactions.accessible_by(user).active

      scope = filter_active_accounts(scope)
      scope = filter_accounts(scope)
      scope = filter_categories(scope)
      scope = filter_merchants(scope)
      scope = filter_types(scope)
      scope = filter_search(scope)
      filter_amount(scope)
    end

    # As in Transaction::Search, the list shows only draft and active accounts
    # unless active_accounts_only is turned off.
    def filter_active_accounts(scope)
      return scope unless ActiveModel::Type::Boolean.new.cast(filters.fetch(:active_accounts_only, true))

      scope.where(account_id: family.accounts.where(status: %w[draft active]).select(:id))
           .or(scope.where(account_id: nil))
    end

    # A transfer shows in the list under both of its accounts, so a series
    # matches on either end.
    def filter_accounts(scope)
      account_ids = []
      account_ids << family.accounts.where(name: filters[:accounts]).pluck(:id) if filters[:accounts].present?
      account_ids << Array(filters[:account_ids]) if filters[:account_ids].present?

      account_ids.reduce(scope) do |filtered, ids|
        filtered.where(account_id: ids).or(filtered.where(destination_account_id: ids))
      end
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
        "income" => "#{EXPECTED_AMOUNT_SQL} < 0 AND recurring_transactions.destination_account_id IS NULL",
        "expense" => "#{EXPECTED_AMOUNT_SQL} >= 0 AND recurring_transactions.destination_account_id IS NULL",
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
      when "equal" then scope.where("ABS(ABS(#{EXPECTED_AMOUNT_SQL}) - ?) <= 0.01", amount.to_f.abs)
      when "less" then scope.where("ABS(#{EXPECTED_AMOUNT_SQL}) < ?", amount.to_f.abs)
      when "greater" then scope.where("ABS(#{EXPECTED_AMOUNT_SQL}) > ?", amount.to_f.abs)
      else scope
      end
    end

    def expected_amount(series)
      series.manual? && series.expected_amount_avg.present? ? series.expected_amount_avg : series.amount
    end

    # Which series match does not depend on the window, so it is not in the key.
    def cache_key
      applied = filters.except(*IGNORED_FILTERS, :start_date, :end_date).sort.to_h
      [
        "transactions_projected_recurring/v8", family.id, user.id, Date.current,
        Digest::SHA256.hexdigest(applied.to_json), @cache_version
      ].join("/")
    end

    def parse_date(value)
      Date.iso8601(value.to_s) if value.present?
    rescue Date::Error
      nil
    end
end
