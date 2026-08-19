class RecurringTransaction
  # The one declared-bill build path, shared by the add-bill form and the AI
  # create tool so the two can never drift on the rules that matter here:
  # the account must be one the user can actually reach, and the amount
  # carries the sign convention (income is stored negative).
  class DeclaredBill
    attr_reader :family, :user, :attrs

    def initialize(family:, user:, attrs:)
      @family = family
      @user = user
      @attrs = attrs
    end

    def build
      account = user.accessible_accounts.find_by(id: attrs[:account_id])
      due = begin
        Date.parse(attrs[:first_due_on].to_s)
      rescue Date::Error
        nil
      end

      is_income = ActiveModel::Type::Boolean.new.cast(attrs[:is_income]) || false
      # BigDecimal parses "Infinity" and "NaN" as non-finite numbers; both are
      # invalid here, same as unparseable input.
      amount = begin
        BigDecimal(attrs[:amount].to_s.presence || "0").abs
      rescue ArgumentError
        nil
      end
      amount = nil if amount && !amount.finite?
      amount = -amount if amount && is_income

      recurring = family.recurring_transactions.new(
        name: attrs[:name],
        amount: amount,
        bill_type: is_income ? "income" : "bill",
        account: account,
        currency: account&.currency || family.currency,
        payment_url: attrs[:payment_url],
        autopay: ActiveModel::Type::Boolean.new.cast(attrs[:autopay]) || false,
        notes: attrs[:notes],
        status: "active",
        manual: true,
        occurrence_count: 0
      )
      recurring.frequency_preset = attrs[:frequency_preset]
      recurring.first_due_on = attrs[:first_due_on]

      if amount.nil?
        recurring.errors.add(:base, I18n.t("recurring_transactions.create.amount_invalid"))
        return recurring
      end

      if due.nil?
        recurring.errors.add(:base, I18n.t("recurring_transactions.create.due_date_required"))
        return recurring
      end

      recurring.expected_day_of_month = due.day
      recurring.anchor_date = due
      recurring.last_occurrence_date = due
      recurring.next_expected_date = due

      FrequencyPreset.apply(
        recurring,
        preset: attrs[:frequency_preset],
        day_of_month: due.day,
        weekday: due.wday,
        month_of_year: due.month
      )

      recurring
    end

    # A series for this identifier may already exist; a second legitimate one
    # (another tier from the same biller) is distinguished by its amount, so
    # the amount is stamped into dedup_scope before the first insert. The same
    # identity at the same amount then collides immediately and is reported as
    # a validation error rather than an escaping exception.
    def self.save(recurring)
      recurring.dedup_scope = recurring.amount.to_d.to_s("F") if recurring.dedup_scope.blank?
      recurring.save
    rescue ActiveRecord::RecordNotUnique
      recurring.errors.add(:base, I18n.t("recurring_transactions.create.already_exists"))
      false
    end
  end
end
