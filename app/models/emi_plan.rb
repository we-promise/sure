# Converts a single purchase into an EMI (Equated Monthly Installment) plan,
# similar to Bluecoins' "Split into installments" feature.
#
# Given a principal, an annual interest rate, and a tenure in months, this
# generates one future-dated Entry per installment (principal + interest
# share, amortized), plus an optional one-time processing fee entry charged
# immediately.
#
# The original purchase entry becomes the "parent" — its Transaction#kind is
# switched to emi_purchase so it's excluded from budget analytics (the real
# monthly spend is represented by the generated installment entries instead,
# same way a credit card statement's "purchase" isn't double counted against
# the later "payment").
class EmiPlan < ApplicationRecord
  include Monetizable

  belongs_to :entry
  belongs_to :account
  belongs_to :processing_fee_entry, class_name: "Entry", optional: true

  has_many :installment_entries, -> { order(:emi_installment_number) },
           class_name: "Entry", foreign_key: :emi_plan_id, dependent: :nullify

  monetize :principal_amount, :processing_fee

  STATUSES = %w[active foreclosed completed].freeze

  validate :entry_id_must_be_unique
  validates :principal_amount, numericality: { greater_than: 0 }
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :tenure_months, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 480 }
  validates :processing_fee, numericality: { greater_than_or_equal_to: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :start_date, presence: true
  validate :start_date_within_reasonable_range

  # Standard reducing-balance EMI formula:
  #   EMI = P * r * (1 + r)^n / ((1 + r)^n - 1)
  # where r is the *monthly* rate. A 0% rate degrades to a plain principal / n split.
  #
  # Returns an array of n hashes, one per installment, each summing principal +
  # interest back to the original principal (last installment absorbs any
  # rounding remainder so the total always reconciles exactly).
  #
  # @return [Array<Hash>] [{ number:, principal:, interest:, total: }, ...]
  def amortization_schedule
    return @amortization_schedule if defined?(@amortization_schedule)

    monthly_rate = (interest_rate.to_d / 100) / 12
    n = tenure_months
    p = principal_amount.to_d

    emi = if monthly_rate.zero?
      (p / n).round(2)
    else
      factor = (1 + monthly_rate) ** n
      (p * monthly_rate * factor / (factor - 1)).round(2)
    end

    schedule = []
    remaining_principal = p

    n.times do |i|
      number = i + 1
      last_installment = number == n

      if last_installment
        # Pay off exactly what's left, so the schedule always sums back to
        # the original principal regardless of rounding drift on earlier rows.
        principal_component = remaining_principal
        interest_component = monthly_rate.zero? ? 0.to_d : (emi - principal_component)
      else
        interest_component = monthly_rate.zero? ? 0.to_d : (remaining_principal * monthly_rate).round(2)
        principal_component = emi - interest_component
      end

      interest_component = [ interest_component, 0.to_d ].max.round(2)
      principal_component = principal_component.round(2)
      remaining_principal -= principal_component

      schedule << {
        number: number,
        principal: principal_component,
        interest: interest_component,
        total: (principal_component + interest_component).round(2)
      }
    end

    @amortization_schedule = schedule
  end

  def monthly_installment_amount
    return Money.new(0, currency) if tenure_months.zero?
    Money.new(amortization_schedule.first[:total], currency)
  end

  def total_interest
    Money.new(amortization_schedule.sum { |s| s[:interest] }, currency)
  end

  def total_payable
    Money.new(amortization_schedule.sum { |s| s[:total] } + processing_fee.to_d, currency)
  end

  def currency
    entry.currency
  end

  def active?
    status == "active"
  end

  # Builds the full plan: tags the parent entry, creates the processing fee
  # entry (if any), and creates one child Entry per installment.
  #
  # @return [EmiPlan] self, persisted, with installment_entries populated
  def self.build!(entry:, interest_rate:, tenure_months:, processing_fee: 0, start_date: nil)
    # Locking entry (rather than checking eligibility first and locking
    # after) closes the window where two concurrent requests both read
    # emi_convertible? as true before either has committed: without the
    # lock, both proceed to build a full plan -- fee entry, every
    # installment -- and only the second discovers the conflict at
    # plan.save! via the unique index on emi_plans.entry_id, after having
    # done all that work just to roll it back. With the lock, the second
    # request blocks until the first commits, then re-reads emi_convertible?
    # (which will now correctly be false) and fails fast via the normal
    # ActiveRecord::RecordInvalid path below -- no wasted writes, and no
    # reliance on the unique index as the only thing standing between two
    # plans on one entry.
    entry.with_lock do
      unless entry.transaction? && entry.transaction.emi_convertible?
        raise ActiveRecord::RecordInvalid.new(entry), I18n.t("emi_plans.new.not_convertible")
      end

      principal = entry.amount.abs
      start_date ||= entry.date.next_month

      plan = new(
        entry: entry,
        account: entry.account,
        principal_amount: principal,
        interest_rate: interest_rate,
        tenure_months: tenure_months,
        processing_fee: processing_fee,
        start_date: start_date,
        status: "active"
      )

      plan.save!

      if plan.processing_fee.to_d.positive?
        fee_transaction = Transaction.new(kind: "emi_fee", category_id: entry.transaction.category_id)
        fee_entry = entry.account.entries.create!(
          date: entry.date,
          name: I18n.t("emi_plans.generated_entry_names.processing_fee", name: entry.name),
          amount: plan.processing_fee.to_d,
          currency: entry.currency,
          entryable: fee_transaction,
          user_modified: true # never provider-created; protects it from any future sync/reconciliation logic
        )
        plan.update!(processing_fee_entry: fee_entry)
      end

      plan.amortization_schedule.each do |installment|
        installment_transaction = Transaction.new(kind: "emi_installment", category_id: entry.transaction.category_id)
        entry.account.entries.create!(
          date: plan.start_date.advance(months: installment[:number] - 1),
          name: I18n.t("emi_plans.generated_entry_names.installment", name: entry.name, number: installment[:number], tenure: plan.tenure_months),
          amount: installment[:total],
          currency: entry.currency,
          emi_plan_id: plan.id,
          emi_installment_number: installment[:number],
          entryable: installment_transaction,
          user_modified: true # generated, not synced — same reasoning as the fee entry above
        )
      end

      entry.transaction.changing_emi_kind = true
      entry.transaction.update!(kind: "emi_purchase")
      entry.mark_user_modified!

      plan
    end
  end

  # Cancels the plan. Any installment entries that are still in the future
  # (i.e. haven't "happened" yet) are deleted. Past/today installments are
  # left alone since they represent money that has already moved — deleting
  # them would silently erase real spend history.
  #
  # The parent purchase entry's kind reverts to standard so it counts as a
  # normal expense again for any period not already covered by a posted
  # installment.
  def foreclose!
    Entry.transaction do
      had_posted_installments = posted_installments.exists?
      future_installments = installment_entries.where("entries.date > ?", Date.current).to_a

      # Any principal still outstanding on the cancelled future installments
      # (interest is dropped — no more time will pass for it to accrue).
      # Without this, that principal was never charged anywhere: not on the
      # (excluded) parent purchase, not on any posted installment, and no
      # longer on the deleted future ones — it would silently vanish from
      # budget/balance reporting.
      outstanding_principal = future_installments.sum do |installment|
        row = amortization_schedule.find { |s| s[:number] == installment.emi_installment_number }
        row ? row[:principal] : 0.to_d
      end

      future_installments.each do |installment|
        installment.foreclosing = true
        installment.destroy!
      end

      update!(status: "foreclosed")

      # If not a single installment ever posted, this plan never represented
      # real spend beyond the original purchase — revert it to a normal
      # transaction so it counts in budgets again. If some installments did
      # post, the purchase stays excluded (its spend already happened via
      # those installments) even though no more are coming.
      if had_posted_installments
        if outstanding_principal.positive?
          settlement_transaction = Transaction.new(kind: "emi_installment", category_id: entry.transaction.category_id)
          entry.account.entries.create!(
            date: Date.current,
            name: I18n.t("emi_plans.generated_entry_names.foreclosure_settlement", name: entry.name),
            amount: outstanding_principal,
            currency: entry.currency,
            emi_plan_id: id,
            emi_installment_number: tenure_months + 1,
            entryable: settlement_transaction,
            user_modified: true
          )
        end
      else
        entry.transaction.changing_emi_kind = true
        entry.transaction.update!(kind: "standard")
      end

      entry.mark_user_modified!
    end
  end

  def remaining_installments
    installment_entries.where("entries.date > ?", Date.current)
  end

  def posted_installments
    installment_entries.where("entries.date <= ?", Date.current)
  end

  private

    # Not using Rails' built-in `validates :entry_id, uniqueness: true` here.
    # In testing it was observed generating a nonsensical query
    # (`WHERE emi_plans.id IS NULL`, checking this record's own -- unsaved,
    # nil -- primary key instead of entry_id), silently allowing duplicates
    # past app-level validation entirely. Root cause not fully pinned down;
    # implementing the check explicitly here sidesteps it and is exactly as
    # correct, since `where(entry_id:).exists?` cannot make the same mistake.
    # The DB-level unique index on emi_plans.entry_id remains the real
    # source of truth regardless -- this is purely for a clean, catchable
    # RecordInvalid instead of a raw RecordNotUnique for the common,
    # non-racing case.
    def entry_id_must_be_unique
      return if entry_id.blank?

      scope = EmiPlan.where(entry_id: entry_id)
      scope = scope.where.not(id: id) if persisted?

      errors.add(:entry_id, "has already been taken") if scope.exists?
    end

    def start_date_within_reasonable_range
      return if start_date.blank?

      if start_date < Date.current - 5.years
        errors.add(:start_date, "can't be more than 5 years in the past")
      elsif start_date > Date.current + 5.years
        errors.add(:start_date, "can't be more than 5 years in the future")
      end
    end
end
