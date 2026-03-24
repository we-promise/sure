require "digest/md5"

class IncomeStatement
  include Monetizable

  monetize :median_expense, :median_income

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  def totals(transactions_scope: nil, date_range:)
    # Default to excluding pending transactions from budget/analytics calculations
    # Pending transactions shouldn't affect budget totals until they post
    transactions_scope ||= family.transactions.visible.excluding_pending

    result = totals_query(transactions_scope: transactions_scope, date_range: date_range)

    total_income = result.select { |t| t.classification == "income" }.sum(&:total)
    total_expense = result.select { |t| t.classification == "expense" }.sum(&:total)

    ScopeTotals.new(
      transactions_count: result.sum(&:transactions_count),
      income_money: Money.new(total_income, family.currency),
      expense_money: Money.new(total_expense, family.currency)
    )
  end

  def expense_totals(period: Period.current_month)
    build_period_total(classification: "expense", period: period)
  end

  def income_totals(period: Period.current_month)
    build_period_total(classification: "income", period: period)
  end

  def net_category_totals(period: Period.current_month)
    expense = expense_totals(period: period)
    income = income_totals(period: period)

    # Use a stable key for each category: id for persisted, invariant token for synthetic
    cat_key = ->(ct) {
      if ct.category.uncategorized?
        :uncategorized
      elsif ct.category.other_investments?
        :other_investments
      else
        ct.category.id
      end
    }

    expense_by_cat = expense.category_totals.reject { |ct| ct.category.subcategory? }.index_by { |ct| cat_key.call(ct) }
    income_by_cat = income.category_totals.reject { |ct| ct.category.subcategory? }.index_by { |ct| cat_key.call(ct) }

    all_keys = (expense_by_cat.keys + income_by_cat.keys).uniq
    raw_expense_categories = []
    raw_income_categories = []

    all_keys.each do |key|
      exp_ct = expense_by_cat[key]
      inc_ct = income_by_cat[key]
      exp_total = exp_ct&.total || 0
      inc_total = inc_ct&.total || 0
      net = exp_total - inc_total
      category = exp_ct&.category || inc_ct&.category

      if net > 0
        raw_expense_categories << { category: category, total: net }
      elsif net < 0
        raw_income_categories << { category: category, total: net.abs }
      end
    end

    total_net_expense = raw_expense_categories.sum { |r| r[:total] }
    total_net_income = raw_income_categories.sum { |r| r[:total] }

    net_expense_categories = raw_expense_categories.map do |r|
      weight = total_net_expense.zero? ? 0 : (r[:total].to_f / total_net_expense) * 100
      CategoryTotal.new(category: r[:category], total: r[:total], currency: family.currency, weight: weight)
    end

    net_income_categories = raw_income_categories.map do |r|
      weight = total_net_income.zero? ? 0 : (r[:total].to_f / total_net_income) * 100
      CategoryTotal.new(category: r[:category], total: r[:total], currency: family.currency, weight: weight)
    end

    NetCategoryTotals.new(
      net_expense_categories: net_expense_categories,
      net_income_categories: net_income_categories,
      total_net_expense: total_net_expense,
      total_net_income: total_net_income,
      currency: family.currency
    )
  end

  def median_expense(interval: "month", category: nil)
    if category.present?
      category_stats(interval: interval).find { |stat| stat.classification == "expense" && stat.category_id == category.id }&.median || 0
    else
      family_stats(interval: interval).find { |stat| stat.classification == "expense" }&.median || 0
    end
  end

  def avg_expense(interval: "month", category: nil)
    if category.present?
      category_stats(interval: interval).find { |stat| stat.classification == "expense" && stat.category_id == category.id }&.avg || 0
    else
      family_stats(interval: interval).find { |stat| stat.classification == "expense" }&.avg || 0
    end
  end

  def median_income(interval: "month")
    family_stats(interval: interval).find { |stat| stat.classification == "income" }&.median || 0
  end

  private
    ScopeTotals = Data.define(:transactions_count, :income_money, :expense_money)
    PeriodTotal = Data.define(:classification, :total, :currency, :category_totals)
    CategoryTotal = Data.define(:category, :total, :currency, :weight)
    NetCategoryTotals = Data.define(:net_expense_categories, :net_income_categories, :total_net_expense, :total_net_income, :currency)

    def categories
      @categories ||= family.categories.all.to_a
    end

    def build_period_total(classification:, period:)
      # Exclude pending transactions from budget calculations
      totals = totals_query(transactions_scope: family.transactions.visible.excluding_pending.in_period(period), date_range: period.date_range).select { |t| t.classification == classification }
      classification_total = totals.sum(&:total)

      uncategorized_category = family.categories.uncategorized
      other_investments_category = family.categories.other_investments

      category_totals = [ *categories, uncategorized_category, other_investments_category ].map do |category|
        subcategory = categories.find { |c| c.id == category.parent_id }

        parent_category_total = if category.uncategorized?
          # Regular uncategorized: NULL category_id and NOT uncategorized investment
          totals.select { |t| t.category_id.nil? && !t.is_uncategorized_investment }&.sum(&:total) || 0
        elsif category.other_investments?
          # Other investments: NULL category_id AND is_uncategorized_investment
          totals.select { |t| t.category_id.nil? && t.is_uncategorized_investment }&.sum(&:total) || 0
        else
          totals.select { |t| t.category_id == category.id }&.sum(&:total) || 0
        end

        children_totals = if category.synthetic?
          0
        else
          totals.select { |t| t.parent_category_id == category.id }&.sum(&:total) || 0
        end

        category_total = parent_category_total + children_totals

        weight = (category_total.zero? ? 0 : category_total.to_f / classification_total) * 100

        CategoryTotal.new(
          category: category,
          total: category_total,
          currency: family.currency,
          weight: weight,
        )
      end

      PeriodTotal.new(
        classification: classification,
        total: category_totals.reject { |ct| ct.category.subcategory? }.sum(&:total),
        currency: family.currency,
        category_totals: category_totals
      )
    end

    def family_stats(interval: "month")
      @family_stats ||= {}
      @family_stats[interval] ||= Rails.cache.fetch([
        "income_statement", "family_stats", family.id, interval, family.entries_cache_version
      ]) { FamilyStats.new(family, interval:).call }
    end

    def category_stats(interval: "month")
      @category_stats ||= {}
      @category_stats[interval] ||= Rails.cache.fetch([
        "income_statement", "category_stats", family.id, interval, family.entries_cache_version
      ]) { CategoryStats.new(family, interval:).call }
    end

    def included_account_ids
      @included_account_ids ||= user ? user.finance_accounts.pluck(:id) : nil
    end

    def totals_query(transactions_scope:, date_range:)
      sql_hash = Digest::MD5.hexdigest(transactions_scope.to_sql)
      account_ids_hash = included_account_ids ? Digest::MD5.hexdigest(included_account_ids.sort.join(",")) : nil

      Rails.cache.fetch([
        "income_statement", "totals_query", "v2", family.id, user&.id, account_ids_hash, sql_hash, family.entries_cache_version
      ]) { Totals.new(family, transactions_scope: transactions_scope, date_range: date_range, included_account_ids: included_account_ids).call }
    end

    def monetizable_currency
      family.currency
    end
end
