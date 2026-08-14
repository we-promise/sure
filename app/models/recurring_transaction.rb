class RecurringTransaction < ApplicationRecord
  include Monetizable

  # Upper bound on a declared installment run. The generator materialises a
  # finite plan whole, so this is the ceiling on how many occurrence rows a
  # single save can create.
  MAX_END_AFTER_COUNT = 600

  belongs_to :family
  belongs_to :account, optional: true
  belongs_to :destination_account, optional: true, class_name: "Account"
  belongs_to :merchant, optional: true
  belongs_to :category, optional: true
  belongs_to :replaced_by, optional: true, class_name: "RecurringTransaction"
  # autosave so rule rewrites are atomic with the parent save: FrequencyPreset
  # marks old rules for destruction and builds replacements in one assignment,
  # and only autosave honors mark_for_destruction on save.
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
  # A finite plan materialises its whole run, so this number decides how many
  # rows one save writes. 600 covers a 50-year monthly plan and a 10-year
  # weekly one, well past anything a person enters by hand.
  validates :end_after_count,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_END_AFTER_COUNT },
            allow_nil: true
  validate :merchant_or_name_present
  validate :category_belongs_to_family
  validate :amount_variance_consistency
  validate :transfer_endpoints_consistent
  validate :payment_url_is_http
  validate :anchor_required_for_intervals
  validate :end_mode_fields_consistent
  validate :bill_type_matches_shape

  normalizes :payment_url, with: ->(url) { normalize_payment_url(url) }

  before_validation :derive_transfer_bill_type

  # Columns whose change reshapes the occurrence stream. Amount is absent on
  # purpose: open occurrences inherit their expected amount at read time, so a
  # price edit needs no regeneration at all.
  SCHEDULE_SHAPING_ATTRIBUTES = %w[
    expected_day_of_month anchor_date end_mode end_on end_after_count weekend_adjust status currency
  ].freeze

  # Set by FrequencyPreset when it rewrites the rules; cleared after the
  # post-commit regeneration consumes it.
  attr_accessor :rules_rewritten

  after_commit :generate_occurrences, on: :create
  after_commit :regenerate_future_occurrences, on: :update, if: :schedule_shape_changed?
  after_commit :pin_amount_on_dates_already_due, on: :update, if: :saved_change_to_amount?

  # Form state for the frequency picker and the create-bill dialog;
  # FrequencyPreset and the controller translate these on save. Not persisted.
  attr_accessor :frequency_preset, :frequency_day_of_month, :frequency_second_day_of_month,
                :frequency_weekday, :frequency_month_of_year, :first_due_on, :is_income

  # A scheme, followed by either "//" or by something that is not a port number.
  # "example.com:8080" is a host and port, not a scheme, so it does not match.
  EXPLICIT_SCHEME = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*:(?://|(?!\d))}

  # Users paste "verizon.com" as often as "https://verizon.com", so a bare host is
  # promoted to https rather than rejected. Mirrors FamilyMerchant#extract_domain.
  #
  # Anything carrying an explicit scheme is left exactly as typed so that validation
  # can reject it on the merits. Prefixing "javascript:alert(1)" into
  # "https://javascript:alert(1)" would both hide what the user entered and make the
  # rejection an accident of URI parsing rather than a decision.
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

  def payment_url?
    payment_url.present?
  end

  # A recurring transaction is identified by its merchant when it has one and by its
  # free-text name otherwise; `merchant_or_name_present` guarantees one of the two.
  # What the user calls this bill, which is not the same question as what it
  # matches on. A name they typed wins over the detected merchant, otherwise
  # renaming a detected bill would silently do nothing. The matcher keeps
  # reading the merchant directly, because matching really is by merchant.
  def display_name
    name.presence || merchant&.name
  end

  def merchant_or_name_present
    if merchant_id.blank? && name.blank?
      errors.add(:base, :merchant_or_name_required)
    end
  end

  # category_id is a permitted parameter, and nothing else checks whose
  # category it is. Without this a crafted id attaches another household's
  # category to this bill, which then renders its name and colour.
  def category_belongs_to_family
    return if category_id.blank? || family_id.blank?

    unless Category.where(id: category_id, family_id: family_id).exists?
      errors.add(:category_id, :invalid)
    end
  end

  def payment_url_is_http
    return if payment_url.blank?

    errors.add(:payment_url, :invalid_scheme) unless self.class.valid_payment_url?(payment_url)
  end

  def generate_occurrences
    OccurrenceGenerator.new(self).generate!
  end

  # Regenerating deletes only scheduled, allocation-free, not-yet-due rows and
  # rebuilds them under the new shape; anything closed or carrying payments is
  # untouched. Pausing/ending a series prunes its re-generatable future the
  # same way, because generate! refuses non-active series.
  def regenerate_future_occurrences
    self.rules_rewritten = false
    OccurrenceGenerator.new(self).regenerate_future!
  end

  def schedule_shape_changed?
    rules_rewritten || (previous_changes.keys & SCHEDULE_SHAPING_ATTRIBUTES).any?
  end

  # A price change means "it costs this much from now on", not "it always cost
  # this much". Occurrences resolve their amount from the series live, so
  # without this, raising the rent rewrites what last month's unpaid rent
  # claims you owe, and the past-due total on the Overview with it.
  #
  # Dates already due keep what they claimed; future dates pick up the new
  # amount. Rows carrying a payment are already pinned by the allocator, and
  # closed rows are out of scope, so only open, unpinned, on-or-before-today
  # rows need stamping.
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

  # A destination account IS the definition of a transfer, so the
  # classification derives from the shape rather than asking every creation
  # path to remember it. The validation guards only the reverse: a row
  # claiming to be a transfer without the shape would route through pair
  # matching with no pair to match.
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
        errors.add(:expected_amount_min, "cannot be greater than expected_amount_max")
      end
    end
  end

  # When this row represents a recurring transfer, both endpoints must be
  # present, belong to the same family, and not be the same account.
  def transfer_endpoints_consistent
    return if destination_account_id.blank?

    if account_id.blank?
      errors.add(:account, "must be present on a recurring transfer")
    elsif account.blank?
      # account_id references a row that was destroyed. Mirror the
      # destination_account.blank? branch so the source side surfaces a
      # normal validation error too.
      errors.add(:account, "must exist")
    elsif destination_account.blank?
      # destination_account_id references a row that was destroyed (or never
      # existed). Surface as a normal validation error instead of letting
      # the FK fire on save.
      errors.add(:destination_account, "must exist")
    elsif account_id == destination_account_id
      errors.add(:destination_account, "cannot be the same as the source account")
    elsif account.family_id != destination_account.family_id
      errors.add(:destination_account, "must belong to the same family as the source account")
    end
  end

  def transfer?
    destination_account_id.present?
  end

  scope :for_family, ->(family) { where(family: family) }
  scope :expected_soon, -> { active.where("next_expected_date <= ?", 1.month.from_now) }

  # A bill is an active recurring *expense* you owe someone. Transfers are internal
  # moves between your own accounts, and income is not owed, so neither belongs on a
  # list of things to pay. Expenses are stored positive, matching the convention
  # `Insight::Generators::SubscriptionAuditGenerator` already relies on.
  #
  # Deliberately no minimum amount: a threshold would be an arbitrary number that is
  # wrong in some currency. A trivial row the user does not consider a bill is
  # handled by the existing pause action, which is what it is for.
  scope :bills, -> { active.where(destination_account_id: nil).where("amount > 0") }

  # Everything the Bills page owes an answer for: expense bills and
  # subscriptions, PLUS recurring transfers into liability accounts -- a
  # credit-card or loan payment is a real obligation with a real due date,
  # even though it is a transfer and not spending. (It stays excluded from
  # any budget/category math for exactly that reason.)
  scope :payable, -> {
    debt_accounts = Account.where(accountable_type: %w[CreditCard Loan]).select(:id)

    active.where("amount > 0")
          .merge(where(destination_account_id: nil).or(where(destination_account_id: debt_accounts)))
  }

  # The bills that actually want something from you. A bill on autopay still belongs on
  # the list -- you want to know it is coming and what it will cost -- but it is not a
  # task, and a list that cannot tell the two apart makes the user re-derive that every
  # month from memory.
  scope :needs_action, -> { where(autopay: false) }

  # The stored `next_expected_date` can sit a whole cycle too far out.
  # `calculate_next_expected_date` always jumps to `last_occurrence_date.next_month`, so
  # a payment that posts earlier in the month than the bill's expected day skips the
  # occurrence still ahead in the current month: a rent bill due on the 29th, last paid
  # on the 6th, is recorded as due *next* month. Compare
  # `calculate_next_expected_date_from_today` a few lines up, which handles exactly that
  # case correctly.
  #
  # Bills has to answer "what do I owe now", so it derives the date instead of trusting
  # the stored one. Correcting what gets persisted changes what the Identifier and the
  # Cleaner write, so it belongs with the scheduling work rather than here.
  # For installment plans: how many payments are done, out of how many.
  # nil when the series has no declared payment count.
  def installment_progress
    return nil unless typed_installment? && end_after_count.present?

    [ recurring_occurrences.paid.count, end_after_count ]
  end

  # The occurrence the user most needs to see: the earliest still-open one
  # (which is also the most overdue), falling back to the most recent closed
  # one when everything is settled.
  def current_occurrence
    recurring_occurrences.open_status.order(:due_on).first ||
      recurring_occurrences.order(due_on: :desc).first
  end

  def next_due_date
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

  # Deliberately strict: same name ignoring case and spacing, same amount, *and* same
  # expected day. Loosening any one of those starts flagging genuinely separate
  # subscriptions to one merchant -- three concurrent Twitch tiers at different prices
  # on different days are three real bills, and telling someone to merge them is worse
  # than saying nothing. The pairs this does catch are the ones detection split by
  # casing, which are unambiguous.
  def duplicate_key
    [ display_name.to_s.downcase.gsub(/\s+/, " ").strip, amount, expected_day_of_month ]
  end

  # How many whole cycles have elapsed since this was due, using the series'
  # real cadence length.
  def cycles_overdue
    return 0 unless overdue?

    cycle_days = 365.25 / schedule.occurrences_per_year
    ((Date.current - next_due_date).to_i / cycle_days).floor + 1
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
      currency: entry.currency,
      expected_day_of_month: expected_day,
      last_occurrence_date: entry.date,
      next_expected_date: next_expected,
      status: "active",
      bill_type: entry.amount.negative? ? "income" : "bill",
      occurrence_count: matching_amounts.size,
      manual: true,
      expected_amount_min: expected_min,
      expected_amount_max: expected_max,
      expected_amount_avg: expected_avg
    }

    create!(attributes)
  rescue ActiveRecord::RecordNotUnique
    # A series for this identifier already exists (identity no longer includes
    # amount). A second legitimate series for one merchant -- another
    # subscription tier, say -- is distinguished by stamping its amount into
    # dedup_scope. Retried once; a true duplicate (same amount too) re-raises
    # for the caller's existing already-exists handling.
    scoped = attributes.merge(dedup_scope: entry.amount.to_d.to_s("F"))
    raise if where(scoped.slice(:family, :account, :merchant_id, :name, :currency, :dedup_scope)).exists?

    create!(scoped)
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

  # Find matching transactions for this recurring pattern
  def matching_transactions
    # Recurring transfers can't be matched by single-account name/amount —
    # future occurrences carry arbitrary names — so match the Transfer pair.
    return transfer_matching_transactions if transfer?

    # Amount/cadence-scoped Transaction entries on this account (or family).
    base = account.present? ? account.entries : family.entries
    entries = day_of_month_scope(
      amount_window_scope(base.where(entryable_type: "Transaction").where(currency: currency))
    ).order(date: :desc)

    # Filter by merchant or name
    if merchant_id.present?
      # Match by merchant through the entryable (Transaction)
      entries.select do |entry|
        entry.entryable.is_a?(Transaction) && entry.entryable.merchant_id == merchant_id
      end
    else
      # Match by entry name
      entries.where(name: name)
    end
  end

  # True only when the observed amounts actually SPREAD. Detection records a
  # band for every cluster, so a perfectly stable bill carries a degenerate
  # band (min == max) -- displaying that as "~amount" would claim an
  # approximation where there is none, and matching against it is identical
  # to an exact match anyway.
  def has_amount_variance?
    expected_amount_min.present? && expected_amount_max.present? &&
      expected_amount_min < expected_amount_max
  end

  # A series is stale after two missed cycles of ITS OWN cadence, floored at
  # the old flat thresholds (2 months auto, 6 months manual) so a weekly bill
  # is not retired after a fortnight's gap. The cycle term is what stops a
  # quarterly or annual bill being auto-retired between its perfectly normal
  # occurrences -- under the flat threshold every non-monthly bill died.
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
    # observed variance band when one has been recorded. Auto-detected rows
    # carry a band too now that detection clusters within tolerance instead of
    # requiring exact amounts.
    def amount_window_scope(relation)
      if has_amount_variance?
        relation.where("entries.amount BETWEEN ? AND ?", expected_amount_min, expected_amount_max)
      else
        relation.where("entries.amount = ?", amount)
      end
    end

    # Entries whose day-of-month lands within the schedule's tolerance of the
    # expected day, on the circular calendar with short-month clamping. This is
    # the same matcher the Identifier applies to manual rows; the two disagreed
    # for bills on the 1st and the 31st before being unified here.
    def day_of_month_scope(relation)
      relation.where(Schedule.day_window_sql,
                     expected_day: expected_day_of_month,
                     tolerance: Schedule::DAY_MATCH_TOLERANCE)
    end

    def monetizable_currency
      currency
    end
end
