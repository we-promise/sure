# frozen_string_literal: true

module BankdataImport
  class SyncSummary
    STATUSES = %i[created already_imported uncategorized invalid failed skipped].freeze

    attr_reader :items

    def initialize(items = [])
      @items = items
    end

    def total = items.size

    STATUSES.each do |status|
      define_method(status) { items.count { |item| item[:status].to_s == status.to_s } }
    end

    def uncategorized
      items.count do |item|
        item[:status].to_s == "uncategorized" || (item[:status].to_s == "created" && item[:category_name].blank?)
      end
    end

    def income_total
      side_total("Income")
    end

    def expense_total
      side_total("Expense")
    end

    def as_json(*)
      {
        total: total,
        created: created,
        already_imported: already_imported,
        uncategorized: uncategorized,
        invalid: invalid,
        failed: failed,
        skipped: skipped,
        income_total: income_total,
        expense_total: expense_total,
        items: items
      }
    end

    private
      def side_total(side)
        total = items.sum do |item|
          next BigDecimal("0") unless item[:income_expense].to_s == side

          BigDecimal(item[:amount].to_s)
        rescue ArgumentError
          BigDecimal("0")
        end

        format("%.2f", total)
      end
  end
end
