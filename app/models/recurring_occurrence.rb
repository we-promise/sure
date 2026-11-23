# One expected instance of a recurring obligation: the August rent, this
# month's electric bill. Holds what is specific to the instance (due date,
# amount override, skip/snooze, payments via allocations); the rest inherits
# from the series.
#
# Stored status is minimal -- scheduled, plus the terminal paid / skipped /
# missed. Upcoming, due, overdue and partially paid all derive from dates and
# allocation sums, so they cannot drift stale. `missed` is only ever set by the
# user.
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
  # Historical rows are past cycles generated from a bill's started_on. They
  # stay linkable from the bill's history, but they are never the bill's
  # current cycle and never count as debt.
  scope :current_open, -> { open_status.where(historical: false) }
  scope :history, -> { where(historical: true).or(closed) }
  scope :closed, -> { where.not(status: :scheduled) }
  scope :due_between, ->(from, to) { where(due_on: from..to) }

  # The family's open bill occurrences due within `dates`, with their confirmed
  # allocation sums and their series' spending shares loaded in grouped
  # queries so remaining_spending_money on each row issues none. `series`
  # narrows the bills read, e.g. to those the whole family may see.
  def self.open_bills_due(family, dates, series: RecurringTransaction.all)
    occurrences = current_open
                    .joins(:recurring_transaction)
                    .merge(RecurringTransaction.bills)
                    .merge(series)
                    .where(recurring_transactions: { family_id: family.id })
                    .where(due_on: dates)
                    .includes(:recurring_transaction)
                    .to_a

    sums = RecurringAllocation.confirmed
                              .where(recurring_occurrence_id: occurrences.map(&:id))
                              .group(:recurring_occurrence_id)
                              .sum(:allocated_amount)
    shares = spending_shares(family, occurrences.map(&:recurring_transaction_id).uniq)
    occurrences.each do |occurrence|
      occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0)
      occurrence.spending_share = shares.fetch(occurrence.recurring_transaction_id, 1)
    end
  end

  # The part of each series' charge that is spending, by series id, for the
  # series whose charges get split: a mortgage instalment split into its
  # interest and a transfer of the principal to the loan is spending only for
  # the interest. Read off the series' latest split charge, as its children
  # that count as spending over the charge: the family's reported kinds
  # (Family#analytics_excluded_kinds, so a contribution to an investment
  # account counts only when the family counts investing as spending, as in
  # IncomeStatement::Totals) and not excluded. Series never split are absent:
  # all spending.
  def self.spending_shares(family, series_ids)
    latest_splits = RecurringAllocation.confirmed
      .joins(:recurring_occurrence, :entry)
      .where(recurring_occurrences: { recurring_transaction_id: series_ids })
      .where(entry_id: Entry.where.not(parent_entry_id: nil).select(:parent_entry_id))
      .order("recurring_occurrences.recurring_transaction_id", "entries.date DESC", "entries.id DESC")
      .pluck(Arel.sql("DISTINCT ON (recurring_occurrences.recurring_transaction_id) recurring_occurrences.recurring_transaction_id"),
             "entries.id", "entries.amount")
    return {} if latest_splits.empty?

    spent = Entry.where(parent_entry_id: latest_splits.map(&:second), excluded: false, entryable_type: "Transaction")
                 .where(entryable_id: Transaction.where.not(kind: family.analytics_excluded_kinds).select(:id))
                 .group(:parent_entry_id)
                 .sum(:amount)

    latest_splits.each_with_object({}) do |(series_id, entry_id, amount), shares|
      shares[series_id] = (spent.fetch(entry_id, 0) / amount).clamp(0, 1) if amount.positive?
    end
  end

  # The amount this occurrence expects, resolving NULL through the series'
  # amount strategy, which is what lets a price edit update every open
  # occurrence with no sweep. `series_amount` overrides what the series says it
  # costs now, so a price change can pin what a row claimed before the edit.
  def resolved_expected_amount(series_amount: nil)
    return expected_amount if expected_amount.present?

    series = recurring_transaction
    fallback = series_amount || series.amount

    case series.amount_strategy
    when "average"
      series.expected_amount_avg.presence || fallback
    when "last"
      last_paid_total.presence || fallback
    else
      fallback
    end.abs
  end

  def resolved_expected_amount_money
    Money.new(resolved_expected_amount, currency)
  end

  # effective_due_on as SQL, for queries that select by it. GREATEST skips a
  # NULL snoozed_until the way compact does below.
  EFFECTIVE_DUE_ON_SQL = "GREATEST(recurring_occurrences.due_on, recurring_occurrences.snoozed_until)".freeze

  # Snoozing postpones the presentation-level due date without rewriting the
  # schedule.
  def effective_due_on
    [ due_on, snoozed_until ].compact.max
  end

  # List views preload allocation sums in one grouped query and inject them
  # here, so row rendering issues no per-occurrence SUM.
  attr_writer :cached_confirmed_allocated

  def self.preload_confirmed_allocated(occurrences)
    sums = RecurringAllocation.confirmed
                              .where(recurring_occurrence_id: occurrences.map(&:id))
                              .group(:recurring_occurrence_id)
                              .sum(:allocated_amount)
    occurrences.each { |occurrence| occurrence.cached_confirmed_allocated = sums.fetch(occurrence.id, 0) }
  end

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

  attr_writer :spending_share

  # The part of remaining_amount that will be spending: all of it, unless the
  # series' charges get split (see .spending_shares).
  def remaining_spending_money
    share = @spending_share || self.class.spending_shares(family, [ recurring_transaction_id ]).fetch(recurring_transaction_id, 1)
    Money.new((remaining_amount * share).round(Money::Currency.new(currency).default_precision), currency)
  end

  # Exact sum, not tolerance: $1,850 allocated against $2,000 rent is
  # partially paid with $150 remaining, always.
  def partially_paid?
    scheduled? && confirmed_allocated.positive? && confirmed_allocated < resolved_expected_amount
  end

  # Overpaid means beyond the tolerance band the matcher uses. A payment inside
  # the band is the bill's real amount, not an overpayment.
  def overpaid?
    confirmed_allocated > resolved_expected_amount + overpaid_threshold
  end

  # Presentation state for open occurrences: upcoming until the notify
  # window, due through the grace period, overdue after it.
  def derived_state
    return status.to_sym unless scheduled?
    return :historical if historical?

    today = Date.current

    if today > effective_due_on + grace_days
      :overdue
    elsif today >= effective_due_on - notify_days
      :due
    else
      :upcoming
    end
  end

  # Nobody is paying a bill that isn't active, so its leftover is neither late
  # nor due, whatever the dates say. derived_state stays the raw schedule
  # state: the matcher reads it to keep a late payment able to settle the
  # leftover.
  def overdue?
    recurring_transaction.active? && derived_state == :overdue
  end

  def due?
    recurring_transaction.active? && derived_state == :due
  end

  # --- Lifecycle actions. Closing freezes the resolved amount so the row is
  # self-contained history; reopening keeps that value as an explicit override
  # rather than un-freezing it. ---

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
    def overpaid_threshold
      band = resolved_expected_amount * (recurring_transaction.effective_amount_tolerance_pct / BigDecimal("100"))
      [ band, CLOSE_EPSILON ].max
    end

    def notify_days
      recurring_transaction.notify_days_before || DEFAULT_NOTIFY_DAYS
    end

    def grace_days
      recurring_transaction.overdue_grace_days || DEFAULT_GRACE_DAYS
    end

    # What the last settled cycle actually cost. `expected_amount` on a closed
    # row is the frozen estimate, so reading it would re-propose the guess and
    # strategy could never converge on a variable bill's real amount.
    # Memoized: every amount label on a row asks this same question.
    def last_paid_total
      return @last_paid_total if defined?(@last_paid_total)

      @last_paid_total = begin
        previous = recurring_transaction.recurring_occurrences
                                        .paid
                                        .where("due_on < ?", due_on)
                                        .order(due_on: :desc)
                                        .first
        if previous
          total = previous.allocations.confirmed.sum(:allocated_amount)
          total.positive? ? total : nil
        end
      end
    end
end
