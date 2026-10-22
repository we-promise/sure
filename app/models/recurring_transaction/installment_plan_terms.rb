class RecurringTransaction
  # Changes the terms of a plan before its first charge.
  #
  # The plan is the loan schedule: its principal, rate, term and first due date
  # are the inputs to the same amortisation engine the purchase plan used. A
  # change rebuilds the projected occurrences from the anchor, so the dates and
  # amounts on the plan page still match the schedule.
  #
  # Once anything is matched to the plan, this is refused. Rebuilding rows
  # would erase the payment or suggestion attached to them.
  class InstallmentPlanTerms
    MAX_TERM_MONTHS = RecurringTransaction::MAX_END_AFTER_COUNT

    attr_reader :plan, :interest_rate, :term_months, :first_due_on,
                :interest_category

    def initialize(plan:, interest_rate:, term_months:, first_due_on:,
                   interest_category_id: nil)
      @plan = plan
      @interest_rate = interest_rate
      @term_months = term_months
      @first_due_on = first_due_on
      @interest_category_id = interest_category_id
      @interest_category = plan.family.categories.find_by(id: interest_category_id) if interest_category_id.present?
    end

    def call
      plan.errors.clear

      unless plan.financed_terms_editable?
        plan.errors.add(:base, :installment_plan_terms_locked)
        return plan
      end

      apply_problems
      return plan if plan.errors.any?

      schedule = build_schedule
      if schedule.payments.empty?
        plan.errors.add(:base, :installment_plan_invalid_term)
        return plan
      end

      plan.assign_attributes(terms_attributes(schedule))

      begin
        plan.financed_terms_update = true
        saved = plan.save
      ensure
        plan.financed_terms_update = false
      end
      return plan unless saved

      rebuild_occurrences!
      plan
    end

    private
      def apply_problems
        plan.errors.add(:base, :installment_plan_missing_purchase) if plan.financed_source_entry.blank?
        plan.errors.add(:base, :installment_plan_invalid_rate) unless valid_rate?
        plan.errors.add(:base, :installment_plan_invalid_term) unless valid_term?
        plan.errors.add(:base, :installment_plan_invalid_first_due) unless valid_first_due?
        if @interest_category_id.present? && interest_category.blank?
          plan.errors.add(:base, :installment_plan_invalid_interest_category)
        end
      end

      def valid_rate?
        annual_rate.present? && annual_rate.finite? &&
          annual_rate >= 0 && annual_rate <= 100
      end

      def valid_term?
        term_months.to_i.positive? && term_months.to_i <= MAX_TERM_MONTHS
      end

      def valid_first_due?
        purchase_date = plan.financed_source_entry&.date
        first_due_on.present? && purchase_date.present? && first_due_on >= purchase_date
      end

      def build_schedule
        Loan::AmortizationSchedule.new(
          principal: plan.financed_principal_amount,
          annual_rate: annual_rate,
          term_months: term_months.to_i,
          start_date: first_due_on.prev_month,
          currency: plan.currency
        )
      end

      def terms_attributes(schedule)
        {
          amount: schedule.periodic_payment.amount,
          end_mode: "after_count",
          end_after_count: term_months.to_i,
          anchor_date: first_due_on,
          expected_day_of_month: first_due_on.day,
          last_occurrence_date: first_due_on,
          next_expected_date: first_due_on,
          financed_interest_rate: annual_rate,
          financed_interest_category_id: interest_category&.id
        }
      end

      # The plan is the schedule, so the projected rows have to follow the
      # terms. Everything is unallocated here, so deleting and rebuilding from
      # the anchor cannot lose a payment.
      def rebuild_occurrences!
        plan.recurring_occurrences.delete_all
        OccurrenceGenerator.new(plan).backfill!(
          from: plan.anchor_date,
          through: plan.financed_payoff_date
        )
        plan.stamp_financed_instalment_amounts!
      end

      def annual_rate
        return nil if interest_rate.blank?

        BigDecimal(interest_rate.to_s)
      rescue ArgumentError, FloatDomainError
        nil
      end
  end
end
