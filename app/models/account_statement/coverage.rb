# frozen_string_literal: true

class AccountStatement::Coverage
  Month = Struct.new(:date, :status, :statements, :ambiguous_statements, keyword_init: true) do
    def expected?
      status != "not_expected"
    end

    def covered?
      status == "covered"
    end

    def missing?
      status == "missing"
    end

    def duplicate?
      status == "duplicate"
    end

    def ambiguous?
      status == "ambiguous"
    end

    def mismatched?
      status == "mismatched"
    end

    def not_expected?
      status == "not_expected"
    end
  end

  attr_reader :account, :start_month, :end_month, :expected_start_month, :expected_end_month, :selected_year, :available_years

  class << self
    def for_year(account, year)
      expected_end_month = default_expected_end_month
      expected_start_month = default_expected_start_month(account, fallback_end_month: expected_end_month)
      available_years = years_between(expected_start_month, expected_end_month)
      selected_year = resolve_year_value(year, available_years)

      new(
        account,
        start_month: Date.new(selected_year, 1, 1),
        end_month: Date.new(selected_year, 12, 1),
        expected_start_month: expected_start_month,
        expected_end_month: expected_end_month,
        selected_year: selected_year,
        available_years: available_years
      )
    end

    def years_for(account)
      expected_end_month = default_expected_end_month
      expected_start_month = default_expected_start_month(account, fallback_end_month: expected_end_month)

      years_between(expected_start_month, expected_end_month)
    end

    def resolve_year(account, year)
      resolve_year_value(year, years_for(account))
    end

    def default_expected_end_month
      Date.current.prev_month.beginning_of_month
    end

    def default_expected_start_month(account, fallback_end_month: default_expected_end_month)
      candidates = [
        account.entries.minimum(:date),
        account.balances.minimum(:date),
        account.account_statements.where.not(period_start_on: nil).minimum(:period_start_on),
        account.family.account_statements.unmatched.where(suggested_account: account).where.not(period_start_on: nil).minimum(:period_start_on)
      ].compact

      start_month = (candidates.min || fallback_end_month.advance(months: -11)).to_date.beginning_of_month
      start_month > fallback_end_month ? fallback_end_month : start_month
    end

    private

      def years_between(start_month, end_month)
        (start_month.year..end_month.year).to_a.reverse
      end

      def resolve_year_value(year, available_years)
        requested_year = year.to_i if year.present?

        available_years.include?(requested_year) ? requested_year : available_years.first
      end
  end

  def initialize(account, start_month: nil, end_month: nil, expected_start_month: nil, expected_end_month: nil, selected_year: nil, available_years: nil)
    raise ArgumentError, "account is required" if account.nil?

    @account = account
    @expected_end_month = (expected_end_month || end_month || self.class.default_expected_end_month).to_date.beginning_of_month
    resolved_expected_start_month = (expected_start_month || start_month || self.class.default_expected_start_month(account, fallback_end_month: @expected_end_month)).to_date.beginning_of_month
    @expected_start_month = resolved_expected_start_month > @expected_end_month ? @expected_end_month : resolved_expected_start_month
    @start_month = (start_month || @expected_start_month).to_date.beginning_of_month
    @end_month = (end_month || @expected_end_month).to_date.beginning_of_month
    @selected_year = selected_year
    @available_years = available_years || self.class.years_for(account)
  end

  def months
    @months ||= begin
      current = start_month
      result = []

      while current <= end_month
        result << build_month(current)
        current = current.next_month
      end

      result
    end
  end

  def summary_counts
    months.group_by(&:status).transform_values(&:count)
  end

  private

    def build_month(month)
      return Month.new(date: month, status: "not_expected", statements: [], ambiguous_statements: []) unless expected_month?(month)

      linked_statements = statements_covering(linked_statement_scope, month)
      ambiguous_statements = statements_covering(ambiguous_statement_scope, month)

      status = if linked_statements.size > 1
        "duplicate"
      elsif linked_statements.any? { |statement| statement.reconciliation_mismatched?(balance_lookup: balance_lookup) }
        "mismatched"
      elsif linked_statements.one?
        "covered"
      elsif ambiguous_statements.any?
        "ambiguous"
      else
        "missing"
      end

      Month.new(date: month, status: status, statements: linked_statements, ambiguous_statements: ambiguous_statements)
    end

    def expected_month?(month)
      month >= expected_start_month && month <= expected_end_month
    end

    def linked_statement_scope
      @linked_statement_scope ||= account.account_statements
        .where("period_start_on <= ? AND period_end_on >= ?", end_month.end_of_month, start_month)
        .ordered
        .to_a
    end

    def ambiguous_statement_scope
      @ambiguous_statement_scope ||= account.family.account_statements
        .unmatched
        .where(suggested_account: account)
        .where("period_start_on <= ? AND period_end_on >= ?", end_month.end_of_month, start_month)
        .ordered
        .to_a
    end

    def statements_covering(statements, month)
      month_start = month.to_date.beginning_of_month
      month_end = month_start.end_of_month

      statements.select do |statement|
        statement.period_start_on.present? &&
          statement.period_end_on.present? &&
          statement.period_start_on <= month_end &&
          statement.period_end_on >= month_start
      end
    end

    def balance_lookup
      @balance_lookup ||= begin
        currencies = linked_statement_scope.map(&:statement_currency).compact.uniq
        dates = linked_statement_scope.flat_map { |statement| [ statement.period_start_on, statement.period_end_on ] }.compact.uniq
        balances = if currencies.any? && dates.any?
          account.balances.where(currency: currencies, date: dates).to_a
        else
          []
        end
        by_key = balances.index_by { |balance| [ balance.date, balance.currency ] }

        ->(date, currency) { by_key[[ date, currency ]] }
      end
    end
end
