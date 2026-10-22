class RecurringTransaction
  # Records the principal and interest of one plan charge.
  #
  # The issuer already replaced the purchase with a charge for the monthly
  # payment. The plan knows how much of that payment is interest, so this
  # splitter keeps the principal under the purchase category and puts the
  # interest under the plan's financing category. It uses the existing split
  # engine, so the charge still pays the occurrence through its allocation;
  # only the reporting shape changes.
  #
  # The split needs one full allocation against this occurrence. Partial
  # payments stay whole, because splitting part of a charge would attribute
  # interest that the user has not paid yet.
  class FinancedChargeSplitter
    attr_reader :occurrence, :entry

    def initialize(occurrence:, entry:)
      @occurrence = occurrence
      @entry = entry
    end

    def split!
      return false unless splittable?

      entry.split!(split_rows)
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.warn(
        "[FinancedChargeSplitter] could not split entry=#{entry.id} " \
        "occurrence=#{occurrence.id}: #{e.class}: #{e.message}"
      )
      false
    end

    # Removes the split when the payment is unlinked. The parent charge must
    # count again, so only a split that still matches the plan is undone. A
    # user-edited split is left alone and logged.
    def unsplit!
      return false unless unsplittable?

      entry.unsplit!
      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.warn(
        "[FinancedChargeSplitter] could not unsplit entry=#{entry.id} " \
        "occurrence=#{occurrence.id}: #{e.class}: #{e.message}"
      )
      false
    end

    private
      def series
        @series ||= occurrence.recurring_transaction
      end

      def installment
        @installment ||= series.financed_installment_for(occurrence)
      end

      def amount
        @amount ||= entry.amount.abs.to_d
      end

      def interest
        return @interest if defined?(@interest)

        @interest = [ installment[:interest].amount.to_d, amount ].min
      end

      def principal
        amount - interest
      end

      def splittable?
        entry.present? &&
          entry.persisted? &&
          entry.entryable_type == "Transaction" &&
          entry.amount.positive? &&
          !entry.excluded? &&
          !entry.split_parent? &&
          !entry.split_child? &&
          series.financed? &&
          series.financed_interest_category_id.present? &&
          series.category_id != series.financed_interest_category_id &&
          installment.present? &&
          interest.positive? &&
          principal.positive? &&
          full_allocation?
      end

      # One confirmed allocation for this exact occurrence, for the whole
      # entry. Two allocations mean a partial payment, which stays whole.
      def full_allocation?
        allocations = entry.recurring_allocations.confirmed.to_a
        return false unless allocations.size == 1

        allocation = allocations.first
        allocation.recurring_occurrence_id == occurrence.id &&
          allocation.allocated_amount.to_d == amount
      end

      def split_rows
        [
          {
            name: I18n.t("recurring_transactions.financed_charge.principal_name", name: entry.name),
            amount: principal,
            category_id: series.category_id,
            excluded: false
          },
          {
            name: I18n.t("recurring_transactions.financed_charge.interest_name", name: entry.name),
            amount: interest,
            category_id: series.financed_interest_category_id,
            excluded: false
          }
        ]
      end

      def unsplittable?
        entry.present? &&
          entry.split_parent? &&
          series.financed? &&
          series.financed_interest_category_id.present? &&
          series.category_id != series.financed_interest_category_id &&
          installment.present? &&
          interest.positive? &&
          principal.positive? &&
          split_matches_plan?
      end

      def split_matches_plan?
        children = entry.child_entries.includes(:entryable).to_a
        return false unless children.size == 2
        return false unless children.all? { |child| child.entryable_type == "Transaction" }
        return false unless children.sum(BigDecimal("0")) { |child| child.amount.to_d } == amount

        by_category = children.group_by { |child| child.entryable.category_id }
        by_category.transform_values! { |rows| rows.sum(BigDecimal("0")) { |row| row.amount.to_d } }

        by_category == {
          series.category_id => principal,
          series.financed_interest_category_id => interest
        }
      end
  end
end
