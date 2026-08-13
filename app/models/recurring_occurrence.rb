# One expected instance of a recurring obligation: the August rent, this
# month's electric bill. Occurrences hold what is specific to the instance
# (due date, per-instance amount override, skip/snooze state, payments via
# allocations); everything else inherits from the series.
#
# Stored status is deliberately minimal -- scheduled, and the three terminal
# states paid / skipped / missed. Everything else (upcoming, due, overdue,
# partially paid) derives from dates and allocation sums, so it can never
# drift stale. `missed` is only ever set by the user: the system leaves an
# unpaid bill `overdue` forever rather than fabricating "you missed rent".
class RecurringOccurrence < ApplicationRecord
  include Monetizable

  # App defaults when the series leaves its per-bill knobs NULL.
  DEFAULT_NOTIFY_DAYS = 3
  DEFAULT_GRACE_DAYS = 3

  # Rounding epsilon for accumulation close: payments summing to within a
  # cent of the expected amount count as full payment.
  CLOSE_EPSILON = BigDecimal("0.01")

  belongs_to :recurring_transaction
  belongs_to :family
  has_many :allocations, class_name: "RecurringAllocation",
           foreign_key: :recurring_occurrence_id, dependent: :destroy, inverse_of: :recurring_occurrence

  monetize :expected_amount, allow_nil: true

  enum :status, { scheduled: "scheduled", paid: "paid", skipped: "skipped", missed: "missed" }

  validates :original_due_on, :due_on, :currency, presence: true
  validates :expected_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :open_status, -> { where(status: :scheduled) }
  scope :closed, -> { where.not(status: :scheduled) }
  scope :due_between, ->(from, to) { where(due_on: from..to) }

  # The amount this occurrence expects, resolving NULL through the series'
  # amount strategy. NULL-until-frozen is what lets a series price edit
  # update every open occurrence with zero sweeps.
  def resolved_expected_amount
    return expected_amount if expected_amount.present?

    series = recurring_transaction

    case series.amount_strategy
    when "average"
      series.expected_amount_avg.presence || series.amount
    when "last"
      last_paid_total.presence || series.amount
    else
      series.amount
    end.abs
  end

  def resolved_expected_amount_money
    Money.new(resolved_expected_amount, currency)
  end

  # Snoozing postpones the presentation-level due date without rewriting the
  # schedule.
  def effective_due_on
    [ due_on, snoozed_until ].compact.max
  end

  # List views preload allocation sums in one grouped query and inject them
  # here, so row rendering issues no per-occurrence SUM.
  attr_writer :cached_confirmed_allocated

  def confirmed_allocated
    @cached_confirmed_allocated || allocations.confirmed.sum(:allocated_amount)
  end

  def confirmed_allocated_money
    Money.new(confirmed_allocated, currency)
  end

  def remaining_amount
    [ resolved_expected_amount - confirmed_allocated, 0 ].max
  end

  def remaining_amount_money
    Money.new(remaining_amount, currency)
  end

  # Exact sum, not tolerance: $1,850 allocated against $2,000 rent is
  # partially paid with $150 remaining, always.
  def partially_paid?
    scheduled? && confirmed_allocated.positive? && confirmed_allocated < resolved_expected_amount
  end

  def overpaid?
    confirmed_allocated > resolved_expected_amount + CLOSE_EPSILON
  end

  # Presentation state for open occurrences: upcoming until the notify
  # window, due through the grace period, overdue after it.
  def derived_state
    return status.to_sym unless scheduled?

    today = Date.current

    if today > effective_due_on + grace_days
      :overdue
    elsif today >= effective_due_on - notify_days
      :due
    else
      :upcoming
    end
  end

  def overdue?
    derived_state == :overdue
  end

  # --- Lifecycle actions. Closing freezes the resolved amount so the row is
  # immutable, self-contained history whatever later happens to the series;
  # reopening keeps the frozen value as an explicit override rather than
  # un-freezing, which is the least surprising reading. ---

  def close!(new_status, source:)
    update!(
      status: new_status,
      expected_amount: resolved_expected_amount,
      closed_at: Time.current,
      closed_source: source
    )
  end

  def skip!(source: "user")
    close!("skipped", source: source)
  end

  def miss!
    close!("missed", source: "user")
  end

  def reopen!
    update!(status: "scheduled", closed_at: nil, closed_source: nil)
  end

  def snooze!(until_date)
    update!(snoozed_until: until_date)
  end

  def override_amount!(amount)
    update!(expected_amount: amount.presence)
  end

  private
    def notify_days
      recurring_transaction.notify_days_before || DEFAULT_NOTIFY_DAYS
    end

    def grace_days
      recurring_transaction.overdue_grace_days || DEFAULT_GRACE_DAYS
    end

    def last_paid_total
      previous = recurring_transaction.recurring_occurrences
                                      .paid
                                      .where("due_on < ?", due_on)
                                      .order(due_on: :desc)
                                      .first
      previous&.expected_amount
    end
end
