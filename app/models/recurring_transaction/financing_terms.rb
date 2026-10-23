class RecurringTransaction
  # Shared rules for the terms that drive a plan's loan schedule. Creation,
  # the terms editor and the live estimate all use these checks, so the form
  # cannot accept a term that the save path rejects.
  module FinancingTerms
    MAX_TERM_MONTHS = RecurringTransaction::MAX_END_AFTER_COUNT

    module_function

    def parse_rate(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, FloatDomainError
      nil
    end

    def valid_rate?(rate)
      rate.present? && rate.finite? && rate >= 0 && rate <= 100
    end

    def valid_term?(term)
      value = Integer(term.to_s, 10)
      value.positive? && value <= MAX_TERM_MONTHS
    rescue ArgumentError, TypeError
      false
    end

    def valid_first_due?(first_due_on, purchase_date:)
      first_due_on.present? && purchase_date.present? &&
        first_due_on >= purchase_date && first_due_on >= Date.current
    end

    def positive_schedule?(schedule)
      schedule.present? && schedule.payments.any? { |payment| payment.payment.amount.positive? }
    end
  end
end
