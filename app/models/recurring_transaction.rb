# Bills subsystem: this model gained recurrence rules, bill typing
# (bill / subscription / installment / income), payment and pay-run attributes,
# schedule pinning, and the payable scopes the Bills pages read.
class RecurringTransaction < ApplicationRecord
  include Monetizable

  # Ceiling on how many occurrence rows one save can create: the generator
  # materialises a finite plan whole.
  MAX_END_AFTER_COUNT = 600

  belongs_to :family
  belongs_to :account, optional: true
  belongs_to :destination_account, optional: true, class_name: "Account"
  belongs_to :merchant, optional: true
  belongs_to :category, optional: true
  belongs_to :replaced_by, optional: true, class_name: "RecurringTransaction"
  # autosave: FrequencyPreset marks old rules for destruction and builds
  # replacements in one assignment, and only autosave honors that on save.
  has_many :recurrence_rules, -> { order(:position) }, dependent: :destroy, autosave: true
  has_many :recurring_occurrences, dependent: :destroy
  has_many :recurring_match_rejections, dependent: :destroy
  has_many :recurring_price_changes, dependent: :destroy

  monetize :amount
  monetize :expected_amount_min, allow_nil: true
  monetize :expected_amount_max, allow_nil: true
  monetize :expected_amount_avg, allow_nil: true

  # suggested: detector output awaiting user confirmation -- never surfaced as
  #   a real bill, never generates occurrences.
  # paused: deliberately parked by the user; resumable.
  # inactive: auto-retired by the Cleaner after going stale.
  # ended: reached its end condition, was cancelled, or was dismissed from the
  #   suggestion queue -- a tombstone the detector sees and will not recreate.
  enum :status, { suggested: "suggested", active: "active", paused: "paused",
                  inactive: "inactive", ended: "ended" }
  enum :bill_type, { bill: "bill", subscription: "subscription", installment: "installment",
                     income: "income", transfer: "transfer", other: "other" }, prefix: :typed
  enum :amount_strategy, { fixed: "fixed", average: "average", last: "last" }, prefix: :amount
  enum :end_mode, { never: "never", on_date: "on_date", after_count: "after_count" }, prefix: :ends
  enum :weekend_adjust, { none: "none", skip: "skip", before: "before", after: "after" }, prefix: :weekend

  validates :amount, presence: true
  validates :currency, presence: true
  validates :expected_day_of_month, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 31 }
  validates :status, presence: true, inclusion: { in: statuses.keys }
  validates :occurrence_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  # 600 covers a 50-year monthly plan and a 10-year weekly one.
  validates :end_after_count,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_END_AFTER_COUNT },
            allow_nil: true
  validate :merchant_or_name_present
  validate :category_belongs_to_family
  validate :accounts_belong_to_family
  validate :amount_variance_consistency
  validate :transfer_endpoints_consistent
  validate :payment_url_is_http
  validate :anchor_required_for_intervals
  validate :end_mode_fields_consistent
  validate :bill_type_matches_shape

  normalizes :payment_url, with: ->(url) { normalize_payment_url(url) }

  before_validation :derive_transfer_bill_type

  # Columns whose change reshapes the occurrence stream. Amount is absent on
  # purpose: open occurrences inherit it at read time.
  SCHEDULE_SHAPING_ATTRIBUTES = %w[
    expected_day_of_month anchor_date end_mode end_on end_after_count weekend_adjust status currency
  ].freeze

  # Set by FrequencyPreset when it rewrites the rules; cleared after the
  # post-commit regeneration consumes it.
  attr_accessor :rules_rewritten

  after_commit :generate_occurrences, on: :create
  # Ahead of regeneration: activation changes status, so both run, and with
  # load_defaults 7.1+ these run in the order defined. An exception in one
  # stops the rest, so a failed regeneration must not cost the bill its
  # history; reconstruct_history! generates the upcoming rows itself.
  after_commit :reconstruct_history_on_activation, on: :update, if: :activated_from_suggestion?
  after_commit :regenerate_future_occurrences, on: :update, if: :schedule_shape_changed?
  before_save :preserve_detected_name, if: -> { name_changed? && name_was.present? && matcher_hints.to_h["detected_name"].blank? }
  after_commit :pin_amount_on_dates_already_due, on: :update, if: :saved_change_to_amount?

  # Form state for the frequency picker and the create-bill dialog;
  # FrequencyPreset and the controller translate these on save. Not persisted.
  attr_accessor :frequency_preset, :frequency_day_of_month, :frequency_second_day_of_month,
                :frequency_weekday, :frequency_month_of_year, :frequency_interval, :frequency_interval_unit,
                :first_due_on, :is_income

  # A scheme, followed by either "//" or by something that is not a port number.
  # "example.com:8080" is a host and port, not a scheme, so it does not match.
  EXPLICIT_SCHEME = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*:(?://|(?!\d))}

  # A bare host is promoted to https; anything with an explicit scheme is left
  # exactly as typed so validation rejects it on the merits rather than by
  # accident of URI parsing. Mirrors FamilyMerchant#extract_domain.
  def self.normalize_payment_url(url)
    stripped = url.to_s.strip
    return nil if stripped.blank?
    return stripped if stripped.match?(EXPLICIT_SCHEME)

    "https://#{stripped}"
  end

  # The scheme allowlist is the security boundary: it is what keeps a stored
  # "javascript:" or "data:" URL from becoming XSS when rendered as a link.
  # URI::HTTPS subclasses URI::HTTP, so this one check accepts both schemes and
  # nothing else. The host check rejects a bare "https://".
  def self.valid_payment_url?(url)
    return false if url.blank?

    uri = URI.parse(url)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  # Bill amounts and their payments are stored to the column's four decimal
  # places: finer than most currencies, coarser than crypto's eight. An amount
  # finer than that would be rounded on save, and a small enough one to zero,
  # which leaves a bill that can never close. Digits past the finest currency's
  # places are float noise, like 16.990000000000002 from an assistant's JSON
  # number, and are still just rounded away.
  def self.storable_amount?(amount)
    finest = Money::Currency.all.each_value.map { |data| data["default_precision"].to_i }.max
    amount.round(finest) == amount.round(columns_hash["amount"].scale)
  end

  # The step an amount input takes: the currency's own, but never finer than
  # what the column keeps.
  def self.amount_step(currency)
    [ Money::Currency.new(currency).step, 10.0**-columns_hash["amount"].scale ].max
  end

  def payment_url?
    payment_url.present?
  end

  # What the user calls this bill, which is a different question from what it
  # matches on: a typed name wins over the detected merchant, while the matcher
  # keeps reading the merchant directly.
  def display_name
    name.presence || merchant&.name
  end

  # Every name this series answers to, normalised: its own, the name the
  # detector matched on, and the bank texts it has learned. The one place a
  # series' names are compared, so the matcher and the covering check below
  # cannot drift apart.
  def known_names
    ([ name, matcher_name ] + Array(matcher_hints["name_aliases"]))
      .compact.map { |known| RecurringTransaction::Matcher.normalize_name(known) }.to_set
  end

  # The name the detector matched on, kept apart from the user-facing name
  # so renaming a bill does not orphan it from its bank transactions.
  def matcher_name
    matcher_hints.to_h["detected_name"].presence || name
  end

  # A bill first renamed without a stored detected name keeps its original name, so the detector can still claim it.
  def preserve_detected_name
    self.matcher_hints = matcher_hints.to_h.merge("detected_name" => name_was)
  end

  def merchant_or_name_present
    if merchant_id.blank? && name.blank?
      errors.add(:base, :merchant_or_name_required)
    end
  end

  # category_id is mass-assignable and nothing else checks ownership, so a
  # crafted id would attach another family's category to this bill.
  def category_belongs_to_family
    return if category_id.blank? || family_id.blank?

    unless Category.where(id: category_id, family_id: family_id).exists?
      errors.add(:category_id, :invalid)
    end
  end

  # account_id and destination_account_id are mass-assignable like category_id,
  # so a crafted id could attach another family's account to this bill --
  # transfer_endpoints_consistent only compares the endpoints to each other.
  def accounts_belong_to_family
    return if family_id.blank?

    { account: account, destination_account: destination_account }.each do |attribute, record|
      next if record.blank? || record.family_id == family_id

      errors.add(attribute, :wrong_family)
    end
  end

  def payment_url_is_http
    return if payment_url.blank?

    errors.add(:payment_url, :invalid_scheme) unless self.class.valid_payment_url?(payment_url)
  end

  def generate_occurrences
    OccurrenceGenerator.new(self).generate!
  end

  # Links what a bill already paid before it was a bill. Every route that
  # confirms a detection -- the review strip, the pause toggle, the API and
  # the assistant's update_bill -- lands here through the status change.
  # Generation is scoped to this series; the matcher pass inside stays
  # family-wide on purpose (exact-tier, idempotent, and scoping it would need
  # a parallel Matcher entry point). Returns false only when another pipeline
  # holds the family lock.
  def reconstruct_history!
    return true if family.recurring_transactions_disabled?

    Pipeline.with_family_lock(family_id) do
      series_scope = family.recurring_transactions.where(id: id)

      # The current cycle and the upcoming occurrences first, as Pipeline#run!
      # does, so the history pass can match an early payment to the occurrence
      # it was paid ahead of. Idempotent, and it no longer relies on the
      # activation's regeneration having run. Freshly loaded, like the
      # backfiller's, so a pause that committed since this record was read
      # is respected.
      series_scope.find_each { |series| OccurrenceGenerator.new(series).generate! }
      HistoryBackfiller.new(
        family,
        months: Pipeline::FIRST_RUN_BACKFILL_MONTHS,
        series_scope: series_scope
      ).run!
    end
  end

  # Read from the saved change rather than the current status: update_bill
  # assigns every field and saves once, so by now the series reads active
  # whichever route it took.
  def activated_from_suggestion?
    saved_change_to_status?(from: "suggested", to: "active")
  end

  # Skipping under a held lock used to leave the bill without history for
  # good, since the live matcher never looks behind the current cycle.
  #
  # The activation has committed by now, so a failure here must not fail the
  # caller's own write (a toggle, an API update, the assistant's update_bill).
  # It is reported and handed to the job, which retries; the backfill is
  # re-runnable by construction.
  def reconstruct_history_on_activation
    BackfillRecurringHistoryJob.perform_later(id) unless reconstruct_history!
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { recurring_transaction_id: id })
    BackfillRecurringHistoryJob.perform_later(id)
  end

  # Regenerating rebuilds only scheduled, allocation-free, not-yet-due rows;
  # anything closed or carrying payments is untouched.
  def regenerate_future_occurrences
    self.rules_rewritten = false
    OccurrenceGenerator.new(self).regenerate_future!
  end

  def schedule_shape_changed?
    rules_rewritten || (previous_changes.keys & SCHEDULE_SHAPING_ATTRIBUTES).any?
  end

  # A price change applies from now on, not retroactively. Occurrences resolve
  # their amount from the series live, so dates already due are stamped with what
  # they claimed while future ones pick up the new amount. Rows carrying a
  # payment are already pinned by the allocator.
  def pin_amount_on_dates_already_due
    was = previous_changes["amount"]&.first
    return if was.blank?

    recurring_occurrences
      .open_status
      .where(expected_amount: nil)
      .where("due_on <= ?", Date.current)
      .find_each do |occurrence|
        occurrence.update!(expected_amount: occurrence.resolved_expected_amount(series_amount: was))
      end
  end

  # A destination account is the definition of a transfer, so the type derives
  # from the shape rather than every creation path remembering to set it.
  def derive_transfer_bill_type
    self.bill_type = "transfer" if transfer?
  end

  def bill_type_matches_shape
    if typed_transfer? && !transfer?
      errors.add(:bill_type, :transfer_shape_mismatch)
    end
  end

  # An "every N periods" cadence is a phase-shifted grid: without a reference
  # occurrence there is no way to say WHICH biweekly Friday is the right one.
  def anchor_required_for_intervals
    return if anchor_date.present?
    return unless recurrence_rules.reject(&:marked_for_destruction?).any? { |rule| rule.interval.to_i > 1 }

    errors.add(:anchor_date, :required_for_intervals)
  end

  def end_mode_fields_consistent
    case end_mode
    when "on_date"
      errors.add(:end_on, :blank) if end_on.blank?
    when "after_count"
      if end_after_count.blank? || end_after_count.to_i < 1
        errors.add(:end_after_count, :blank)
      end
    end
  end

  def amount_variance_consistency
    if expected_amount_min.present? && expected_amount_max.present?
      if expected_amount_min > expected_amount_max
        errors.add(:expected_amount_min, :greater_than_max)
      end
    end
  end

  # When this row represents a recurring transfer, both endpoints must be
  # present, belong to the same family, and not be the same account.
  def transfer_endpoints_consistent
    return if destination_account_id.blank?

    if account_id.blank?
      errors.add(:account, :required_for_transfer)
    elsif account.blank?
      # account_id references a row that was destroyed. Mirror the
      # destination_account.blank? branch so the source side surfaces a
      # normal validation error too. :required is the stock "must exist".
      errors.add(:account, :required)
    elsif destination_account.blank?
      # destination_account_id references a row that was destroyed (or never
      # existed). Surface as a normal validation error instead of letting
      # the FK fire on save.
      errors.add(:destination_account, :required)
    elsif account_id == destination_account_id
      errors.add(:destination_account, :same_as_source)
    elsif account.family_id != destination_account.family_id
      errors.add(:destination_account, :family_mismatch)
    end
  end

  def transfer?
    destination_account_id.present?
  end

  scope :for_family, ->(family) { where(family: family) }
  scope :expected_soon, -> { active.where("next_expected_date <= ?", 1.month.from_now) }

  # An active recurring expense you owe someone: transfers are internal moves and
  # income is not owed, so neither belongs on a list of things to pay. No minimum
  # amount, since any threshold is wrong in some currency; pause handles the rest.
  scope :bills, -> { active.where(destination_account_id: nil).where("amount > 0") }

  # Everything the Bills page owes an answer for: expense bills and
  # subscriptions, PLUS recurring transfers into liability accounts -- a
  # credit-card or loan payment is a real obligation with a real due date,
  # even though it is a transfer and not spending. (It stays excluded from
  # any budget/category math for exactly that reason.)
  scope :payable, -> {
    # Correlated to the row rather than a free-standing id list: the bare
    # subquery scanned every account in the installation on every call, and
    # the destination must belong to the series' own family.
    debt_destination = Account.where(accountable_type: %w[CreditCard Loan])
                              .where("accounts.id = recurring_transactions.destination_account_id")
                              .where("accounts.family_id = recurring_transactions.family_id")

    active.where("amount > 0")
          .merge(where(destination_account_id: nil).or(where(debt_destination.arel.exists)))
  }

  # The bills that want an action from you. Autopay bills still belong on the
  # list, but they are not tasks.
  scope :needs_action, -> { where(autopay: false) }

  # Derived rather than read from the stored `next_expected_date`, which can sit
  # a cycle too far out when a payment posts earlier than the expected day.
  # For installment plans: how many payments are done, out of how many.
  # nil when the series has no declared payment count.
  def installment_progress
    return nil unless typed_installment? && end_after_count.present?

    [ recurring_occurrences.paid.count, end_after_count ]
  end

  # The occurrence the user most needs to see: the earliest still-open one
  # (which is also the most overdue), falling back to the most recent closed
  # one when everything is settled.
  # Preload-aware: get_bills and the bills page both include occurrences, and
  # this runs once per row.
  def next_open_occurrence
    if recurring_occurrences.loaded?
      recurring_occurrences.select(&:scheduled?).min_by(&:due_on)
    else
      recurring_occurrences.open_status.order(:due_on).first
    end
  end

  def current_occurrence
    recurring_occurrences.open_status.order(:due_on).first ||
      recurring_occurrences.order(due_on: :desc).first
  end

  # The occurrences are the schedule. They are what the app materializes,
  # settles, displays and reports on, so the next one still open is what this
  # bill is actually waiting for.
  #
  # next_expected_date is only a cached hint, and the sole paths that advance
  # it are a sync-time match against a real bank entry and record_occurrence!,
  # which nothing calls. Settle a bill any other way, through mark_paid!, a
  # manual payment or the assistant, and the hint froze on a date in the past
  # for good. This method returned it verbatim, so a fully paid bill reported a
  # due date 45 days gone, answered due_within_days: 3, and was filed as two
  # cycles overdue while its own occurrence sat upcoming.
  #
  # The hint still serves as the fallback for a series with nothing
  # materialized yet.
  def next_due_date
    occurrence = next_open_occurrence
    return occurrence.effective_due_on if occurrence

    return next_expected_date if next_expected_date <= Date.current

    [ next_expected_date, schedule.next_occurrence_from_today ].compact.min
  end

  def overdue?
    next_due_date < Date.current
  end

  # This bill's cost normalized to a per-month figure, whatever its cadence:
  # a $120 annual bill contributes $10, a $10 weekly bill about $43.45. This
  # is the honest number for "recurring commitment" style totals; summing raw
  # amounts across mixed cadences answers no meaningful question.
  def monthly_equivalent_amount
    amount_money * (schedule.occurrences_per_year / 12.0)
  end

  # The newest price changes, most recent first. Sorts in Ruby when a caller
  # preloaded the association so the detail panel costs no extra query.
  def recent_price_changes(count = 5)
    if recurring_price_changes.loaded?
      recurring_price_changes.sort_by(&:effective_on).reverse.first(count)
    else
      recurring_price_changes.order(effective_on: :desc).limit(count)
    end
  end

  # Deliberately strict -- same name ignoring case and spacing, same amount AND
  # same expected day -- so concurrent subscription tiers to one merchant are
  # never flagged as duplicates of each other.
  def duplicate_key
    [ display_name.to_s.downcase.gsub(/\s+/, " ").strip, amount, expected_day_of_month ]
  end

  # How many whole cycles have elapsed since this was due, using the series'
  # real cadence length. Whole is meant literally: a bill one day late has not
  # yet missed a cycle. The trailing +1 this used to carry reported 1 on the
  # first day late, which put a bill inside its own grace period into a section
  # documented as "overdue by at least one whole billing cycle".
  def cycles_overdue
    return 0 unless overdue?

    cycle_days = 365.25 / schedule.occurrences_per_year
    ((Date.current - next_due_date).to_i / cycle_days).floor
  end
  scope :accessible_by, ->(user) {
    accessible_account_ids = Account.accessible_by(user).select(:id)
    # A recurring row is accessible when:
    #   * its account_id is in the user's accessible set or null (legacy rows
    #     with no account scoping survive), AND
    #   * its destination_account_id is also accessible OR null (so a recurring
    #     transfer never leaks into the list of a user without access to BOTH
    #     endpoints).
    where(account_id: accessible_account_ids)
      .or(where(account_id: nil))
      .merge(
        where(destination_account_id: accessible_account_ids)
          .or(where(destination_account_id: nil))
      )
  }

  # Class methods for identification and cleanup
  # Schedules pattern identification with debounce to run after all syncs complete
  def self.identify_patterns_for(family)
    IdentifyRecurringTransactionsJob.schedule_for(family)
    0 # Return immediately, actual count will be determined by the job
  end

  # Synchronous pattern identification (for manual triggers from UI)
  def self.identify_patterns_for!(family)
    Identifier.new(family).identify_recurring_patterns
  end

  def self.cleanup_stale_for(family)
    Cleaner.new(family).cleanup_stale_transactions
  end

  # Create a manual recurring transfer from an existing Transfer pair.
  # Mirrors `create_from_transaction` but populates source + destination
  # accounts and skips merchant / variance lookup -- transfers are
  # account-pair-shaped, not merchant-shaped.
  def self.create_from_transfer(transfer)
    outflow_entry = transfer.outflow_transaction&.entry
    inflow_entry  = transfer.inflow_transaction&.entry

    raise ArgumentError, "transfer is missing one of its entries" unless outflow_entry && inflow_entry

    source_account      = outflow_entry.account
    destination_account = inflow_entry.account
    family              = source_account.family

    expected_day = outflow_entry.date.day
    next_expected = calculate_next_expected_date_from_today(expected_day)

    create!(
      family: family,
      account: source_account,
      destination_account: destination_account,
      merchant_id: nil,
      # Transfer#name yields "Payment to ..." for liability destinations
      # and "Transfer to ..." otherwise, matching Transfer::Creator's
      # name_prefix logic so the recurring row reads consistently with
      # the originating Transfer.
      name: transfer.name,
      amount: outflow_entry.amount, # positive (outflow), per Sure sign convention
      currency: outflow_entry.currency,
      expected_day_of_month: expected_day,
      last_occurrence_date: outflow_entry.date,
      next_expected_date: next_expected,
      status: "active",
      bill_type: "transfer",
      occurrence_count: 1,
      manual: true
    )
  end

  # A candidate amount only counts as "the same fluctuating payment" as the
  # anchor amount if it's within this ratio (2x = may double or halve).
  # Anchored on the target amount (not pairwise) so unrelated charges can't
  # chain together, and expressed as a ratio (not a %-of-target-with-floor)
  # so it's scale-invariant and handles negative (expense) amounts correctly
  # via the signed min/max bounds below.
  AMOUNT_VARIANCE_RATIO = 2

  def self.amount_within_variance_band?(candidate_amount, anchor_amount, ratio: AMOUNT_VARIANCE_RATIO)
    return candidate_amount == anchor_amount if anchor_amount.zero?

    low, high = [ anchor_amount / ratio, anchor_amount * ratio ].minmax
    candidate_amount.between?(low, high)
  end

  # The series in this scope that an entry already belongs to, if any. Guards
  # both ways of turning a transaction into a bill ("Create bill" and "Mark as
  # recurring"), so it sees what the matcher sees: detected series as well as
  # hand-made ones. A declared bill is keyed by name and a detected one by
  # merchant, so the unique indexes never collide between the two.
  #
  # An entry with a confirmed allocation is covered by that series, whatever
  # its identity. Otherwise a non-ended series covers it when it shares the
  # currency and account (an accountless series takes any account), the
  # merchant when the series has one, or else a name the series knows (the
  # entry's own text, or its merchant's name, which is what "Create bill"
  # names a bill after), and an amount inside the variance band, so a second
  # price tier stays creatable. The band is signed, so an inflow never lands
  # inside a bill's band, nor an outflow inside income's. A series the user
  # rejected for this entry ("Not this one") is skipped, as the matcher skips
  # it, so the rejected payment can still become a bill of its own.
  #
  # Identity covers ordinary charges only. The matcher never pays a bill with
  # a transfer leg, and a recurring transfer is keyed by its account pair and
  # has its own "mark as recurring" path, so a transfer leg is covered only
  # through an allocation.
  def self.covering(entry)
    scope = where(family_id: entry.account.family_id).where.not(status: "ended")

    allocated = scope.joins(recurring_occurrences: :allocations)
                     .merge(RecurringAllocation.confirmed)
                     .find_by(recurring_allocations: { entry_id: entry.id })
    return allocated if allocated
    return if entry.entryable.try(:transfer?)

    merchant = entry.entryable.try(:merchant)
    names = [ entry.name, merchant&.name ].compact_blank.map { |name| Matcher.normalize_name(name) }

    scope.where(currency: entry.currency, account_id: [ entry.account_id, nil ], destination_account_id: nil)
         .where.not(id: RecurringMatchRejection.where(entry_id: entry.id).select(:recurring_transaction_id))
         .order(:created_at)
         .find do |series|
           next false unless amount_within_variance_band?(entry.amount, series.amount)

           if series.merchant_id.present?
             series.merchant_id == merchant&.id
           else
             series.known_names.intersect?(names)
           end
         end
  end

  # The row create_from_transaction would collide with, whatever its status.
  # The partial unique indexes ignore status, so an ended series still holds
  # its key after covering has stopped returning it. Mirrors the identity
  # written below: merchant when the transaction has one (the merchant index
  # ignores name), else the entry's name, with the amount as dedup_scope.
  def self.identity_taken_by(transaction)
    entry = transaction.entry
    key = {
      family_id: entry.account.family_id,
      account_id: entry.account_id,
      destination_account_id: nil,
      amount: entry.amount,
      currency: entry.currency,
      dedup_scope: entry.amount.to_d.to_s("F")
    }
    key = if transaction.merchant_id.present?
      key.merge(merchant_id: transaction.merchant_id)
    else
      key.merge(merchant_id: nil, name: entry.name)
    end

    find_by(key)
  end

  # Create a manual recurring transaction from an existing transaction
  # Automatically calculates amount variance from past 6 months of matching transactions
  def self.create_from_transaction(transaction, date_variance: 2)
    entry = transaction.entry
    family = entry.account.family
    expected_day = entry.date.day

    # Find matching transactions from the past 6 months
    matching_amounts = find_matching_transaction_amounts(
      family: family,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      currency: entry.currency,
      expected_day: expected_day,
      amount: entry.amount,
      lookback_months: 6,
      account: entry.account
    )

    # Calculate amount variance from historical data
    expected_min = expected_max = expected_avg = nil
    if matching_amounts.size > 1
      # Multiple transactions found - calculate variance
      expected_min = matching_amounts.min
      expected_max = matching_amounts.max
      expected_avg = matching_amounts.sum / matching_amounts.size
    elsif matching_amounts.size == 1
      # Single transaction - no variance yet
      amount = matching_amounts.first
      expected_min = amount
      expected_max = amount
      expected_avg = amount
    end

    # Calculate next expected date relative to today, not the transaction date
    next_expected = calculate_next_expected_date_from_today(expected_day)

    attributes = {
      family: family,
      account: entry.account,
      merchant_id: transaction.merchant_id,
      name: transaction.merchant_id.present? ? nil : entry.name,
      amount: entry.amount,
      # Identity no longer includes amount, so a second legitimate series for
      # one merchant (another price tier) is distinguished by stamping its
      # amount into dedup_scope before the first insert. The same identity at
      # the same amount then collides immediately instead of slipping past as
      # a duplicate; callers treat the raised RecordNotUnique as "already
      # exists".
      dedup_scope: entry.amount.to_d.to_s("F"),
      currency: entry.currency,
      expected_day_of_month: expected_day,
      last_occurrence_date: entry.date,
      next_expected_date: next_expected,
      status: "active",
      bill_type: entry.amount.negative? ? "income" : "bill",
      # Income stays uncategorised, as detection leaves it.
      category_id: entry.amount.negative? ? nil : transaction.category_id,
      occurrence_count: matching_amounts.size,
      manual: true,
      expected_amount_min: expected_min,
      expected_amount_max: expected_max,
      expected_amount_avg: expected_avg,
      matcher_hints: transaction.merchant_id.present? ? {} : { "detected_name" => entry.name }
    }

    create!(attributes)
  end

  # Find matching transaction entries for variance calculation
  def self.find_matching_transaction_entries(family:, merchant_id:, name:, currency:, expected_day:, amount:, lookback_months: 6, account: nil)
    lookback_date = lookback_months.months.ago.to_date
    amount_low, amount_high = [ amount / AMOUNT_VARIANCE_RATIO, amount * AMOUNT_VARIANCE_RATIO ].minmax

    entries = (account.present? ? account.entries : family.entries)
      .where(entryable_type: "Transaction")
      .where(currency: currency)
      .where("entries.date >= ?", lookback_date)
      .where(Schedule.day_window_sql,
             expected_day: expected_day,
             tolerance: Schedule::DAY_MATCH_TOLERANCE)
      # Only entries whose amount is within the variance band of the target
      # amount count as "the same fluctuating payment" — otherwise unrelated
      # charges that happen to share a merchant/day get averaged together
      # (see issue #2936 follow-up).
      .where("entries.amount BETWEEN ? AND ?", amount_low, amount_high)
      .order(date: :desc)

    # Filter by merchant or name
    if merchant_id.present?
      # Join with transactions table to filter by merchant_id in SQL (avoids N+1)
      entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .where(transactions: { merchant_id: merchant_id })
        .to_a
    else
      entries.where(name: name).to_a
    end
  end

  # Find matching transaction amounts for variance calculation
  def self.find_matching_transaction_amounts(family:, merchant_id:, name:, currency:, expected_day:, amount:, lookback_months: 6, account: nil)
    matching_entries = find_matching_transaction_entries(
      family: family,
      merchant_id: merchant_id,
      name: name,
      currency: currency,
      expected_day: expected_day,
      amount: amount,
      lookback_months: lookback_months,
      account: account
    )

    matching_entries.map(&:amount)
  end

  # Calculate next expected date from today
  def self.calculate_next_expected_date_from_today(expected_day)
    Schedule.new(expected_day_of_month: expected_day).next_occurrence_from_today
  end

  def self.calculate_next_expected_date_for(from_date, expected_day)
    Schedule.new(expected_day_of_month: expected_day).next_occurrence_after(from_date)
  end

  # Find matching transactions for this recurring pattern. SQL narrows to
  # amount/day-window candidates; the schedule then keeps only entries on a
  # real occurrence, so an every-N cadence sheds same-day charges from
  # off-cycle periods (which would keep a dead series alive in Cleaner and
  # pollute variance samples).
  def matching_transactions
    # Recurring transfers can't be matched by single-account name/amount —
    # future occurrences carry arbitrary names — so match the Transfer pair.
    return schedule_matched(transfer_matching_transactions) if transfer?

    # Amount/cadence-scoped Transaction entries on this account (or family).
    base = account.present? ? account.entries : family.entries
    entries = day_of_month_scope(
      amount_window_scope(base.where(entryable_type: "Transaction").where(currency: currency))
    ).order(date: :desc)

    # Filter by merchant or name
    candidates = if merchant_id.present?
      # Match by merchant through the entryable (Transaction)
      entries.includes(:entryable).select do |entry|
        entry.entryable.is_a?(Transaction) && entry.entryable.merchant_id == merchant_id
      end
    else
      # Match by entry name
      entries.where(name: matcher_name)
    end

    schedule_matched(candidates)
  end

  # True only when the observed amounts actually spread. Detection records a band
  # for every cluster, so a stable bill carries a degenerate one (min == max) that
  # must not render as "~amount".
  def has_amount_variance?
    expected_amount_min.present? && expected_amount_max.present? &&
      expected_amount_min < expected_amount_max
  end

  # Stale after two missed cycles of the series' own cadence, floored at 2 months
  # (auto) / 6 months (manual), so quarterly and annual bills survive the gaps
  # between their normal occurrences.
  def staleness_threshold_date
    calendar_floor = (manual? ? 6 : 2).months.ago.to_date
    cycle_days = (2 * 365.25 / schedule.occurrences_per_year).ceil

    [ calendar_floor, cycle_days.days.ago.to_date ].min
  end

  # Check if this recurring transaction should be marked inactive
  def should_be_inactive?
    return false if last_occurrence_date.nil?

    last_occurrence_date < staleness_threshold_date
  end

  # A cadence the user typed is intent; the dates charges land on are
  # observation. Detection keeps refreshing the latter but must not move a
  # schedule someone set by hand. `manual` cannot carry this: it is set at
  # creation and no edit flips it.
  def schedule_pinned?
    matcher_hints.to_h["schedule_pinned_at"].present?
  end

  # Assigns rather than saves: callers are mid-edit and persist the record.
  def pin_schedule
    self.matcher_hints = matcher_hints.to_h.merge("schedule_pinned_at" => Time.current.iso8601)
  end

  # Mark as inactive
  def mark_inactive!
    update!(status: "inactive")
  end

  # Mark as active
  def mark_active!
    update!(status: "active")
  end

  # Update based on a new transaction occurrence
  def record_occurrence!(transaction_date, transaction_amount = nil)
    self.last_occurrence_date = transaction_date
    self.next_expected_date = calculate_next_expected_date(transaction_date)

    # Update amount variance for manual recurring transactions BEFORE incrementing count
    if manual? && transaction_amount.present?
      update_amount_variance(transaction_amount)
    end

    self.occurrence_count += 1
    self.status = "active"
    save!
  end

  # Update amount variance tracking based on a new transaction
  def update_amount_variance(transaction_amount)
    # First sample - initialize everything
    if expected_amount_avg.nil?
      self.expected_amount_min = transaction_amount
      self.expected_amount_max = transaction_amount
      self.expected_amount_avg = transaction_amount
      return
    end

    # Update min/max
    self.expected_amount_min = [ expected_amount_min, transaction_amount ].min if expected_amount_min.present?
    self.expected_amount_max = [ expected_amount_max, transaction_amount ].max if expected_amount_max.present?

    # Calculate new average using incremental formula
    # For n samples with average A_n, adding sample x_{n+1} gives:
    # A_{n+1} = A_n + (x_{n+1} - A_n)/(n+1)
    # occurrence_count includes the initial occurrence, so subtract 1 to get variance samples recorded
    n = occurrence_count - 1  # Number of variance samples recorded so far
    self.expected_amount_avg = expected_amount_avg + ((transaction_amount - expected_amount_avg) / (n + 1))
  end

  # All date math is owned by Schedule; the model keeps thin, signature-stable
  # delegators for its existing callers.
  def schedule
    Schedule.for(self)
  end

  # Calculate the next expected date based on the last occurrence
  def calculate_next_expected_date(from_date = last_occurrence_date)
    schedule.next_occurrence_after(from_date)
  end

  # Get the projected transaction for display
  def projected_entry
    return nil unless active?
    return nil unless next_expected_date.future?

    # Use average amount for manual recurring with variance, otherwise use fixed amount
    display_amount = if manual? && expected_amount_avg.present?
      expected_amount_avg
    else
      amount
    end

    OpenStruct.new(
      date: next_expected_date,
      amount: display_amount,
      currency: currency,
      merchant: merchant,
      name: merchant.present? ? merchant.name : name,
      recurring: true,
      projected: true,
      amount_min: expected_amount_min,
      amount_max: expected_amount_max,
      amount_avg: expected_amount_avg,
      has_variance: has_amount_variance?,
      transfer: transfer?,
      source_account: account,
      destination_account: destination_account
    )
  end

  private
    # Issue #1590: a recurring transfer's future occurrences rarely share the
    # seed's name (user free-text, importer wording, the auto-matcher's
    # "Transfer to ..."), so name-based matching returns [] and the Cleaner
    # would wrongly inactivate a still-active transfer. Match the Transfer
    # *pair* instead — an outflow on the source account paired with an inflow
    # on the destination account, within the usual amount/cadence window — and
    # return the outflow entries (the occurrence-date carrier, consistent with
    # create_from_transfer).
    def transfer_matching_transactions
      return Entry.none unless account && destination_account

      outflow_entries = day_of_month_scope(
        amount_window_scope(account.entries.where(entryable_type: "Transaction").where(currency: currency))
      ).order(date: :desc)

      paired_outflow_transaction_ids = Transfer
        .where(outflow_transaction_id: outflow_entries.select(:entryable_id))
        .where(inflow_transaction_id:
          destination_account.entries.where(entryable_type: "Transaction").select(:entryable_id))
        .pluck(:outflow_transaction_id)

      outflow_entries.where(entryable_id: paired_outflow_transaction_ids)
    end

    # Transaction entries whose amount fits the pattern: exact, or within the
    # observed variance band when one has been recorded.
    def amount_window_scope(relation)
      if has_amount_variance?
        relation.where("entries.amount BETWEEN ? AND ?", expected_amount_min, expected_amount_max)
      else
        relation.where("entries.amount = ?", amount)
      end
    end

    # Ruby-side completion of day_of_month_scope: the SQL window only knows
    # the calendar day, so the full schedule (interval phase, weekday, end
    # conditions, weekend adjustment) prunes the candidates here.
    def schedule_matched(entries)
      full_schedule = schedule
      entries.select { |entry| full_schedule.matches_day?(entry.date) }
    end

    # Entries landing within the schedule's day tolerance, on the circular
    # calendar with short-month clamping.
    def day_of_month_scope(relation)
      relation.where(Schedule.day_window_sql,
                     expected_day: expected_day_of_month,
                     tolerance: Schedule::DAY_MATCH_TOLERANCE)
    end

    def monetizable_currency
      currency
    end
end
