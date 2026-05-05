# frozen_string_literal: true

class AccountStatement::Coverage
  Month = Struct.new(:date, :status, :statements, :ambiguous_statements, keyword_init: true) do
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
  end

  attr_reader :account, :start_month, :end_month

  def initialize(account, start_month: 11.months.ago.to_date.beginning_of_month, end_month: Date.current.beginning_of_month)
    @account = account
    @start_month = start_month
    @end_month = end_month
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
