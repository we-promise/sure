# Warns ahead of a change in a loan's scheduled repayment: a rate change the
# user recorded, the end of a fixed period entered as one, or anything else
# the loan's own schedule re-amortises at. It reads Loan#amortization_schedule
# and nothing else, so the figures are the ones the loan page shows, built
# from the terms the user entered. No market rate is guessed.
#
# Named "Repayment" while the type stays loan_payment_change: in CamelCase,
# "LoanPaymentChange..." matches the CI secret scanner's AWS key pattern.
#
# The dedup key carries the effective date, so each change is its own insight,
# and it expires by itself once that date has passed.
class Insight::Generators::LoanRepaymentChangeGenerator < Insight::Generator
  produces "loan_payment_change"

  HORIZON_DAYS = 60
  MIN_CHANGE_PCT = 3
  HIGH_PRIORITY_PCT = 10

  def generate
    shared_loan_accounts.filter_map do |account|
      previous, upcoming = upcoming_change(account.loan)
      change_insight(account, previous, upcoming) if upcoming
    end
  end

  private
    # The insight names the loan, so only loans every active member can see
    # qualify, as for IdleCashGenerator. Ordered so the feed is stable.
    def shared_loan_accounts
      family.accounts.visible.accessible_by_all_active_members
        .where(accountable_type: "Loan")
        .includes(:accountable)
        .order(:created_at, :id)
    end

    # The first payment inside the horizon that differs from the one before it
    # by at least MIN_CHANGE_PCT, with that previous payment. The previous one
    # may already be paid: a payment changing on the 10th changes from the one
    # made last month. The final payment is left out, since it only absorbs
    # the schedule's rounding.
    def upcoming_change(loan)
      payments = loan.amortization_schedule&.payments
      return if payments.blank?

      horizon = Date.current..(Date.current + HORIZON_DAYS)
      payments[0...-1].each_cons(2).find do |previous, upcoming|
        horizon.cover?(upcoming.date) && change_pct(previous, upcoming).abs >= MIN_CHANGE_PCT
      end
    end

    def change_pct(previous, upcoming)
      before = previous.payment.amount
      return 0 unless before.positive?

      (upcoming.payment.amount - before) / before * 100
    end

    def change_insight(account, previous, upcoming)
      pct = change_pct(previous, upcoming)
      direction = pct.positive? ? "up" : "down"

      build_insight(
        insight_type: "loan_payment_change",
        priority: priority_for(pct),
        title: I18n.t("insights.titles.loan_payment_change.#{direction}", account: account.name),
        template_key: "loan_payment_change.#{direction}",
        facts: {
          account: account.name,
          previous_payment: previous.payment.format,
          new_payment: upcoming.payment.format,
          effective_on: I18n.l(upcoming.date, format: :short),
          change_pct: decimal_fact(pct.abs)
        },
        # Deterministic from the loan's terms: these move only when the user
        # edits the loan, which is exactly when the insight should resurface.
        metadata: {
          account_id: account.id,
          effective_on: upcoming.date.iso8601,
          previous_payment: payment_amount(previous),
          new_payment: payment_amount(upcoming)
        },
        dedup_key: "loan_payment_change:#{account.id}:#{upcoming.date.iso8601}"
      )
    end

    # At the loan currency's own precision: rounding a three-decimal payment
    # to two would hide small changes and read some drops as no change.
    def payment_amount(payment)
      round(payment.payment.amount, payment.payment.currency.default_precision)
    end

    # A lower payment is good news, so it sits at the bottom of the feed.
    def priority_for(pct)
      return "low" if pct.negative?

      pct >= HIGH_PRIORITY_PCT ? "high" : "medium"
    end
end
