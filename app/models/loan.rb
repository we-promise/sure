require "digest"

class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "home_equity" => { short: "Home Equity", long: "Home Equity Loan" },
    "line_of_credit" => { short: "Line of Credit", long: "Line of Credit" },
    "business" => { short: "Business Loan", long: "Business Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  # Loans up to 100 years cover any real mortgage, business, or personal loan
  # term while keeping a rebuild's array allocation, exponentiation, and bulk
  # insert bounded. Matches the DB check constraint in
  # db/migrate/20260903150000_add_amortization_bounds_to_loans.rb.
  MAX_TERM_MONTHS = 1200

  # Which day-count basis this loan's interest accrues on. Held per loan
  # rather than as one global constant because lenders differ: reconciliation
  # against a real statement (#65) showed 43/43 monthly charges resolving under
  # actual/actual where a fixed 365 resolved only 30/43, and that is evidence
  # that a single constant cannot be assumed -- not evidence that actual/actual
  # is right for every lender. `actual_365` stays the default, so an existing
  # loan keeps the figures it already had until someone changes it deliberately.
  DAY_COUNT_CONVENTIONS = InterestAccrual::DAY_COUNT_CONVENTIONS.map(&:to_s).freeze
  DEFAULT_DAY_COUNT_CONVENTION = InterestAccrual::DEFAULT_DAY_COUNT_CONVENTION.to_s

  has_many :amortizations, class_name: "LoanAmortization", dependent: :destroy
  has_many :loan_offset_accounts, dependent: :destroy
  has_many :offset_accounts, through: :loan_offset_accounts, source: :account

  attr_accessor :offset_account_ids

  # Structured {effective_date, rate} rows from the form. The jsonb column is
  # deliberately NOT mass-assignable: permitting a free-form hash would let a
  # request write arbitrary JSON into a column the calculation reads, and
  # Brakeman flags it correctly (risk R13, #14). The form submits pairs and the
  # column is assembled from them.
  attr_reader :rate_changes

  before_save :validate_offset_accounts, if: :offset_account_ids_supplied?
  after_save :sync_offset_accounts, if: :offset_accounts_need_sync?

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :term_months, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_TERM_MONTHS }, allow_nil: true
  validates :interest_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :day_count_convention, inclusion: { in: DAY_COUNT_CONVENTIONS }
  validate :variable_rate_schedule_entries_are_valid

  before_validation :quantize_variable_rate_schedule

  after_save :enqueue_amortization_rebuild, if: :amortization_inputs_changed?

  def monthly_payment
    amortization_schedule.monthly_payment
  end

  def invalidate_offset_cache!
    clear_amortization_schedule_cache!
    @payoff_projection = nil
    @payoff_projection_signature = nil
  end

  # Memoized per instance (and cleared alongside the calculator cache) so a
  # single check-then-rebuild cycle reads Account's mutable, unlocked
  # valuation/currency once and reuses that exact reading everywhere --
  # otherwise the signature persisted with a schedule could describe a
  # different balance than the one actually used to calculate it if a
  # concurrent Account update lands between the two reads.
  def original_balance
    @original_balance ||= Money.new(account.first_valuation_amount, account.currency)
  end

  def account_opening_anchor_date
    @account_opening_anchor_date ||= account.opening_anchor_date
  end

  # Recreate the calculator when any Loan or Account input changes. Account
  # changes do not fire Loan callbacks, so the signature also protects callers
  # that hold onto a Loan instance across an Account update.
  def amortization_schedule
    signature = amortization_schedule_signature
    if @amortization_schedule.nil? || @amortization_schedule_signature != signature
      @amortization_schedule = AmortizationSchedule.new(self)
      @amortization_schedule_signature = signature
    end
    @amortization_schedule
  end

  # Get or create the actual-balance-based payoff projection calculator.
  # Recreated when its inputs change -- primarily account.balance, which
  # (like Account changes generally) does not fire a Loan callback, so a
  # long-lived Loan instance would otherwise keep returning a projection
  # computed against a balance that's since moved.
  def payoff_projection
    signature = payoff_projection_signature
    if @payoff_projection.nil? || @payoff_projection_signature != signature
      @payoff_projection = PayoffProjection.new(self)
      @payoff_projection_signature = signature
    end
    @payoff_projection
  end

  # A fresh (unmemoized) projection modeling a hypothetical extra payment on
  # top of the actual-balance projection above -- "what if I also paid an
  # extra $X/week|month|year". Purely a simulation: never touches
  # account.balance or the persisted schedule. amount/frequency are expected
  # to already be validated at the request boundary (see
  # AccountsController#extra_payment_params); an unsupported frequency
  # raises, matching PayoffProjection.monthly_equivalent's contract.
  def payoff_projection_with_extra(amount:, frequency:)
    extra = PayoffProjection.monthly_equivalent(amount: amount, frequency: frequency, currency: account.currency)
    PayoffProjection.new(self, extra_payment: extra)
  end

  # Chart payload contrasting the original schedule's remaining trajectory
  # against the given projection -- the actual-balance projection
  # (Loan#payoff_projection) by default, or a caller-supplied one (e.g. from
  # #payoff_projection_with_extra) when a what-if is active. Takes the
  # projection itself rather than raw amount/frequency so a caller that also
  # needs the projection for cards/labels computes it once and passes the
  # same instance through, instead of this method silently recomputing it.
  # extra_payment_amount/extra_payment_frequency are only used to build the
  # human-readable label below -- pass them whenever `projection` was built
  # with an extra payment. nil unless there's a real, meaningful divergence
  # to show (mirrors the Schedule tab's summary-card gate, so the chart and
  # cards appear/disappear together).
  def payoff_chart_payload(projection: payoff_projection, extra_payment_amount: nil, extra_payment_frequency: nil)
    # `amortization_schedule` recomputes its memoization signature on every
    # call -- read it once here rather than repeating calls throughout this
    # method (`projection` is already the one instance the caller resolved,
    # per the note above).
    schedule = amortization_schedule

    return nil unless projection.applicable?
    # Materiality (including the one-payment cleanup artefact two
    # independently-terminated simulations produce) is the projection's own
    # business -- see Loan::PayoffProjection#diverges_from_schedule?.
    return nil unless projection.diverges_from_schedule?

    today = Date.current
    scheduled_rows = schedule.display_rows

    {
      today: today.iso8601,
      currency: account.currency,
      # NOTE: these are the *scheduled/contracted* balances from the persisted
      # AmortizationSchedule rows -- what the original schedule predicted for
      # each past date -- not actual historical account-balance snapshots
      # (this app doesn't track those). Named/labeled "scheduled", not
      # "history", so the chart can't be read as showing real past balances.
      # Both scheduled series come from AmortizationSchedule#display_rows, the
      # same source as the table, the summary cards and the payoff projection.
      # Reading loan.amortizations directly here mixed possibly-stale persisted
      # balances with a current payoff date and a current projection, so a loan
      # changed but not yet rebuilt would plot two different loans on one chart
      # (risk R21).
      scheduled_history: scheduled_rows.select { |row| row.payment_date <= today }.map { |row|
        { date: row.payment_date.iso8601, balance: row.ending_balance.to_f }
      },
      current_balance: { date: today.iso8601, balance: projection.current_balance.amount.to_f },
      original_projection: scheduled_rows.select { |row| row.payment_date > today }.map { |row|
        { date: row.payment_date.iso8601, balance: row.ending_balance.to_f }
      },
      accelerated_projection: projection.payments.map { |p|
        { date: p[:payment_date].iso8601, balance: p[:ending_balance].to_f }
      },
      original_payoff_date: schedule.payoff_date&.iso8601,
      accelerated_payoff_date: projection.payoff_date&.iso8601,
      ahead: projection.months_saved.positive?,
      extra_payment_label: extra_payment_label(projection, extra_payment_amount, extra_payment_frequency),
      labels: {
        today: I18n.t("loans.tabs.schedule.chart.today"),
        scheduled: I18n.t("loans.tabs.schedule.chart.scheduled_history"),
        original: I18n.t("loans.tabs.schedule.chart.original_payoff"),
        accelerated: I18n.t("loans.tabs.schedule.chart.accelerated_payoff")
      },
      # Server-built accessible description: an SVG aria-label alone doesn't
      # expose the chart's actual figures to screen-reader/keyboard users.
      # Gives the same key numbers the sighted summary cards above it show.
      aria_label: I18n.t("loans.tabs.schedule.chart.aria_label"),
      aria_description: I18n.t(
        "loans.tabs.schedule.chart.aria_description",
        current_balance: projection.current_balance.to_s,
        original_payoff_date: I18n.l(schedule.payoff_date, format: :long),
        accelerated_payoff_date: I18n.l(projection.payoff_date, format: :long)
      )
    }
  end

  def amortizable?
    amortization_schedule.amortizable?
  end

  # Assembles variable_rate_schedule from the form's rows.
  #
  # Deliberately a writer rather than an attr_accessor fed by a callback. The
  # column is what carries the change, and assigning only an accessor leaves
  # the record un-dirty -- Rails' autosave then skips saving the loan entirely
  # when it is updated through `accountable_attributes`, so a callback would
  # never run and the form would silently save nothing.
  #
  # Values are carried across as given rather than parsed here, so a bad date
  # or a non-numeric rate is rejected by
  # `variable_rate_schedule_entries_are_valid` with the message validation
  # already has, instead of raising mid-assembly and turning a correctable typo
  # into a 500.
  #
  # A repeated effective date resolves to the last row submitted, matching
  # `add_variable_rate_change`'s merge semantics: one date carries one rate,
  # and re-entering it replaces rather than duplicates.
  def rate_changes=(rows)
    @rate_changes = rows
    return if rows.nil?

    rows = rows.values if rows.is_a?(Hash)

    self.variable_rate_schedule = Array(rows).each_with_object({}) do |row, schedule|
      row = row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row
      row = row.symbolize_keys

      next if ActiveModel::Type::Boolean.new.cast(row[:_destroy])

      date = row[:effective_date].to_s.strip
      rate = row[:rate]

      # A row where the user filled in neither field is not an error, it is an
      # unused row from the editor.
      next if date.blank? && rate.to_s.strip.blank?

      schedule[date] = rate
    end
  end

  # Add or update a variable interest rate change on a specific date.
  def add_variable_rate_change(date, rate)
    effective_date = Date.iso8601(date.to_s)
    normalized_rate = BigDecimal(rate.to_s)
    raise ArgumentError, "rate must be a finite number" unless normalized_rate.finite?

    self.variable_rate_schedule = (variable_rate_schedule || {}).stringify_keys.merge(
      effective_date.iso8601 => rate
    )
    save!
  end

  def variable_rates
    (variable_rate_schedule || {}).sort_by { |date, _| Date.iso8601(date.to_s) }
  end

  # Rows for the form, in a shape the form can render without parsing anything.
  #
  # Deliberately not `variable_rates`: that sorts by parsing each key, so when
  # a submission fails validation and the form re-renders to show the error,
  # the invalid date the user just typed would raise inside the view -- turning
  # a correctable typo into a 500, which is the failure the assembly path was
  # written to avoid in the first place.
  #
  # Unparseable dates sort last and are echoed back as entered, so the user can
  # see and fix what they typed.
  def rate_change_rows
    (variable_rate_schedule || {}).map { |date, rate| [ date.to_s, rate ] }
      .sort_by { |date, _| [ parseable_date(date) ? 0 : 1, date ] }
  end

  def current_variable_rate(as_of_date = Date.current)
    rate = variable_rates.reverse.find do |date_str, _|
      Date.iso8601(date_str.to_s) <= as_of_date
    end&.last

    rate.nil? ? interest_rate : normalized_rate(rate)
  end

  # This is derived rather than stored because a persisted "next" date becomes
  # stale when the current date passes it.
  def next_rate_change_date
    return nil unless rate_type == "variable"

    variable_rates.map { |date, _| Date.iso8601(date.to_s) }.find { |date| date > Date.current }
  end

  # Fingerprint every input used by AmortizationSchedule. It lets persisted
  # rows be invalidated when the source change happens on Account data.
  #
  # Reloads the cached account association first: this is compared against
  # by ensure_amortization_schedule_current! *before* it takes a lock (so a
  # signature match can skip the lock+query entirely -- see there), which
  # means it must reflect genuinely fresh account data on its own rather
  # than relying on with_lock's reload to have already refreshed a stale
  # cached association, the way earlier calls in the same object's lifetime
  # could otherwise silently rely on. A plain SELECT is far cheaper than the
  # lock this method exists to let callers avoid.
  def amortization_schedule_signature
    return nil unless account

    account.reload

    components = [
      AmortizationSchedule::ALGORITHM_VERSION,
      account.id,
      original_balance.amount.to_s,
      account.currency,
      account_opening_anchor_date.to_s,
      interest_rate.to_s,
      term_months.to_s,
      rate_type.to_s,
      start_date&.iso8601,
      variable_rates.map { |date, rate| [ date.to_s, normalized_rate(rate).to_s ] }
    ]

    # Only a NON-default convention extends the signature, and it is appended
    # rather than inserted. A signature that changed for every loan would make
    # every persisted schedule stale at once: read paths (the Schedule tab, the
    # amortization_schedule API) check #schedule_current? and enqueue
    # LoanAmortizationRebuildJob when it is false (#39), so the cost is a
    # rebuild of every schedule in the estate -- up to MAX_TERM_MONTHS rows
    # each -- to produce byte-identical figures, since actual/365 is what they
    # were already calculated on. Loans that opt into another basis do get a
    # new signature, which is the rebuild that has to happen.
    components << day_count_convention unless day_count_convention == DEFAULT_DAY_COUNT_CONVENTION

    Digest::SHA256.hexdigest(components.to_json)
  end

  # Rebuild the persisted amortization schedule under a loan lock so readers
  # never observe a delete/insert gap and concurrent rebuilds serialize.
  def rebuild_amortization_schedule
    with_lock { rebuild_amortization_schedule_locked! }
  end

  # Lazily build or replace the persisted schedule when it is missing or stale.
  # This also removes rows when a loan is no longer amortizable.
  #
  # Two layers avoid taking the row lock on the common "nothing to do" path,
  # which matters because this is called from read paths (Schedule tab,
  # amortization_schedule API) as well as writes:
  #   1. Memoized by signature on this in-memory Loan instance -- repeat
  #      calls against the same instance (e.g. a controller ensuring the
  #      schedule, then building a projection that ensures it again) skip
  #      everything below once the schedule is known current for this
  #      signature.
  #   2. A lock-free #schedule_current? check (standard double-checked
  #      locking): only acquire with_lock when that check says a rebuild
  #      might be needed. It's re-verified with the same logic once the lock
  #      is held (below), so a false "not current" from a lock-free read
  #      racing a concurrent writer just costs a redundant lock+no-op --
  #      never an incorrect rebuild.
  # A genuinely stale schedule (interest_rate/term/etc. actually changed)
  # still gets a fresh signature and is rebuilt normally. Callers that must
  # not write on a read should use #schedule_current? instead.
  def ensure_amortization_schedule_current!
    # Clear memoized account-derived values before computing the lock-free
    # signature so an external Account update cannot be hidden by this Loan's
    # cached balance or opening date.
    clear_amortization_schedule_cache!
    signature = amortization_schedule_signature
    return if @amortization_schedule_ensured_signature == signature
    return if schedule_current_for_signature?(signature)

    with_lock do
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        @amortization_schedule_ensured_signature = signature
        next
      end

      rebuild_amortization_schedule_locked! unless schedule_current_for_signature?(signature)
      @amortization_schedule_ensured_signature = signature
    end
  end

  # Read-only freshness check. `rebuild_amortization_schedule_locked!` always
  # replaces every row for a loan in one transaction under the same
  # signature, so the persisted set is current if and only if a row exists
  # with today's signature -- no need to regenerate the schedule just to
  # count it. Backed by the existing loan_id+schedule_signature index.
  def schedule_current?
    return false unless amortizable?
    amortizations.exists?(schedule_signature: amortization_schedule_signature)
  end

  private

    # Whether the persisted amortizations already match `signature`, with no
    # writes and (on the caller's part) no lock. Used both as the lock-free
    # fast path above and, called again, as the authoritative check once
    # with_lock is held -- same logic either way, just a live query against
    # amortizations either time, never a cached read.
    def schedule_current_for_signature?(signature)
      return !amortizations.exists? unless amortizable?

      schedule = amortization_schedule
      matching_rows = amortizations.where(schedule_signature: signature).count
      matching_rows == schedule.payment_count && amortizations.count == schedule.payment_count
    end

    # Human-readable "+ $50/week" label for the chart/cards, built from the
    # raw amount/frequency the user entered -- not the monthly-equivalent
    # projection.extra_payment, which would misleadingly show "$216.67/month"
    # for a $50/week input. nil when no extra payment is active or it turned
    # out to be a no-op (blank/zero amount).
    def extra_payment_label(projection, raw_amount, raw_frequency)
      return nil unless projection.extra_payment.present?
      return nil if raw_amount.blank? || raw_frequency.blank?

      I18n.t(
        "loans.tabs.schedule.chart.extra_payment_applied",
        amount: Money.new(BigDecimal(raw_amount.to_s), account.currency).to_s,
        frequency: I18n.t("loans.tabs.schedule.chart.frequency.#{raw_frequency}")
      )
    rescue ArgumentError, TypeError
      nil    end

    def rebuild_amortization_schedule_locked!
      clear_amortization_schedule_cache!

      unless amortizable?
        amortizations.delete_all if amortizations.exists?
        reset_amortizations_association!
        return
      end

      schedule = amortization_schedule
      signature = amortization_schedule_signature
      now = Time.current
      rows = schedule.payments.map do |payment_data|
        {
          loan_id: id,
          payment_number: payment_data[:payment_number],
          payment_date: payment_data[:payment_date],
          payment_amount: payment_data[:payment_amount],
          principal_payment: payment_data[:principal_payment],
          interest_payment: payment_data[:interest_payment],
          beginning_balance: payment_data[:beginning_balance],
          ending_balance: payment_data[:ending_balance],
          interest_rate: payment_data[:interest_rate],
          schedule_signature: signature,
          algorithm_version: AmortizationSchedule::ALGORITHM_VERSION,
          generated_at: now,
          created_at: now,
          updated_at: now
        }
      end

      transaction do
        amortizations.delete_all
        LoanAmortization.insert_all!(rows) if rows.any?
      end
      reset_amortizations_association!
    end

    def amortization_inputs_changed?
      saved_change_to_interest_rate? ||
        saved_change_to_term_months? ||
        saved_change_to_rate_type? ||
        saved_change_to_start_date? ||
        saved_change_to_day_count_convention? ||
        saved_change_to_variable_rate_schedule?
    end

    # Enqueues instead of rebuilding inline: a rebuild allocates and inserts
    # up to MAX_TERM_MONTHS rows under a row lock, which shouldn't happen
    # synchronously inside an ordinary save. Deduped per loan via
    # sidekiq-unique-jobs, so a burst of saves collapses to one rebuild.
    def enqueue_amortization_rebuild
      LoanAmortizationRebuildJob.perform_later(id)
    end

    def parseable_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def offset_account_ids_supplied?
      !offset_account_ids.nil?
    end


    def offset_accounts_need_sync?
      offset_account_ids_supplied? || saved_change_to_rate_type?
    end

    def sync_offset_accounts
      ids = rate_type == "variable" ? offset_account_ids_for_sync.map(&:id) : []
      loan_offset_accounts.where.not(account_id: ids).delete_all
      ids.each do |account_id|
        loan_offset_accounts.find_or_create_by!(account_id:)
      end
    end

    def validate_offset_accounts
      return if rate_type != "variable"

      ids = normalized_offset_account_ids
      accounts = offset_account_ids_for_sync
      missing_ids = ids - accounts.map { |account| account.id.to_s }
      errors.add(:offset_account_ids, "contains an unknown account") if missing_ids.any?

      accounts.each do |account|
        link = LoanOffsetAccount.new(loan: self, account:)
        next if link.valid?

        errors.add(:offset_account_ids, link.errors.full_messages.to_sentence)
      end
    end

    def offset_account_ids_for_sync
      Account.where(id: normalized_offset_account_ids).to_a
    end

    def normalized_offset_account_ids
      Array(offset_account_ids).reject(&:blank?).map(&:to_s).uniq
    end

    def normalized_rate(rate)
      BigDecimal(rate.to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "variable interest rates must be numeric"
    end

    def quantize_variable_rate_schedule
      return unless variable_rate_schedule.is_a?(Hash)

      self.variable_rate_schedule = variable_rate_schedule.transform_values do |rate|
        begin
          BigDecimal(rate.to_s).round(3).to_f
        rescue ArgumentError, TypeError
          rate
        end
      end
    end

    def clear_amortization_schedule_cache!
      @amortization_schedule = nil
      @amortization_schedule_signature = nil
      @original_balance = nil
      @account_opening_anchor_date = nil
    end

    def reset_amortizations_association!
      association(:amortizations).reset
    end

    # PayoffProjection's only input beyond AmortizationSchedule's own
    # (already covered by amortization_schedule_signature) is the account's
    # current balance -- combine them so the projection is recreated
    # whenever either changes.
    def payoff_projection_signature
      "#{amortization_schedule_signature}:#{account&.balance}:#{offset_account_signature}"
    end

    def offset_account_signature
      LoanOffsetAccount.joins(:account)
        .where(loan_id: id)
        .order(:account_id)
        .pluck(:account_id, "accounts.balance")
    end

    def variable_rate_schedule_entries_are_valid
      return if variable_rate_schedule.blank?

      unless variable_rate_schedule.is_a?(Hash)
        errors.add(:variable_rate_schedule, "must be a JSON object")
        return
      end

      variable_rate_schedule.each do |date, rate|
        begin
          Date.iso8601(date.to_s)
        rescue ArgumentError
          errors.add(:variable_rate_schedule, "contains an invalid effective date")
        end

        begin
          parsed_rate = BigDecimal(rate.to_s)
          if !parsed_rate.finite?
            errors.add(:variable_rate_schedule, "contains a non-numeric rate")
          elsif parsed_rate.negative? || parsed_rate > 100
            errors.add(:variable_rate_schedule, "contains a rate outside the supported 0-100 range")
          end
        rescue ArgumentError, TypeError
          errors.add(:variable_rate_schedule, "contains a non-numeric rate")
        end
      end
    end

    class << self
      def color
        "#D444F1"
      end

      def icon
        "hand-coins"
      end

      def classification
        "liability"
      end
    end
end
