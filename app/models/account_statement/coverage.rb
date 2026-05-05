# frozen_string_literal: true

class AccountStatement::Coverage
  Month = Struct.new(:date, :status, :statements, :ambiguous_statements, keyword_init: true) do
    def label
      date.strftime("%b %Y")
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
      linked_statements = account.account_statements.for_month(month).ordered.to_a
      ambiguous_statements = account.family.account_statements
        .unmatched
        .where(suggested_account: account)
        .for_month(month)
        .ordered
        .to_a

      status = if linked_statements.size > 1
        "duplicate"
      elsif linked_statements.any?(&:reconciliation_mismatched?)
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
end
