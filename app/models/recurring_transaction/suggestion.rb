# One smart-fill or smart-configure request. The controller enqueues its job,
# the job stores the answer here, and the browser reloads #show from a broadcast
# frame: a broadcast can't carry a form's authenticity token.
class RecurringTransaction::Suggestion < ApplicationRecord
  include Ai::Requester
  ai_feature :bill_setup

  belongs_to :family
  belongs_to :user
  belongs_to :recurring_transaction, optional: true
  belongs_to :entry, class_name: "Entry", optional: true

  enum :mode, { fill: "fill", configure: "configure" }
  enum :status, { pending: "pending", complete: "complete", failed: "failed", cancelled: "cancelled" }

  after_update_commit :deliver_result_broadcast

  Error = Class.new(StandardError)
  MAX_CHARGES = 40

  # Provider errors can quote an account identifier back at us. Mask the
  # shapes that carry one, on top of the AI redactor's key/secret shapes.
  ACCOUNT_IDENTIFIER_PATTERNS = [
    /\b[A-Z]{2}\d{2}(?:[ -]?[A-Z0-9]{1,4}){2,}\b/,
    /\b\d(?:[ -]?\d){9,}\b/
  ].freeze

  # nil means "no proposal for this field"; false is a real proposal (turn
  # autopay off), so presence is non-nil rather than truthy.
  Proposal = Data.define(
    :name, :amount, :frequency, :day_of_month, :weekday, :month_of_year,
    :category_id, :category_name, :bill_type, :autopay, :confidence, :rationale
  ) do
    def any_proposal?
      [ name, amount, frequency, day_of_month, weekday, month_of_year, category_id, bill_type, autopay ].any? { |value| !value.nil? }
    end
  end

  def self.from_ai_job(window:, family_id:, id:, **)
    find_by!(id:, family_id:)
  end

  # The requester protocol. The job rechecks consent here: the user may have
  # switched bill setup off between the click and the worker picking the job up.
  def ai_generation
    availability = Ai.availability(:bill_setup, family:, user:)
    raise Ai::Error::Unavailable.new(availability.reason) unless availability.available?

    series = nil
    charges = if fill?
      # The requester runs later, so the requester's account access is checked
      # again here instead of trusting the access the controller saw at create.
      source = accessible_entries.find_by(id: entry_id)
      raise Error, "Entry is no longer accessible" if source.nil?

      charges_from(evidence_entries(source))
    else
      series = family.recurring_transactions.accessible_by(user).find_by(id: recurring_transaction_id)
      raise Error, "Bill is no longer accessible" if series.nil?
      raise Error, "No charge history to analyze" if series.matching_transactions.none?

      charges_from(series.matching_transactions)
    end
    raise Error, "No charge history to analyze" if charges.empty?

    Ai::Generations::SuggestBillSetup.new(
      charges:, categories: family.categories.pluck(:name), current_config: current_config(series), family:, user:
    )
  end

  # Under the row lock, so a Stop that lands while the answer is in flight wins:
  # a cancelled suggestion keeps its status and never broadcasts an answer.
  def apply_ai(result)
    normalized = normalize(result.value)
    applied = false
    with_lock do
      next unless pending?

      update!(result: normalized.to_h, status: :complete, error: nil)
      applied = true
    end
    applied ? 1 : 0
  end

  def ai_failed(error)
    return if error.is_a?(Ai::Error::Cancelled)

    # Only a router reason is safe to show. Provider text can quote a statement
    # or an account number, so it goes to support logs under a correlation id.
    code = error.is_a?(Ai::Error::Unavailable) ? error.reason.to_s : "generation_failed"
    DebugLogEntry.capture(
      category: "bill_setup", level: "error", message: "Bill suggestion failed",
      source: self.class.name, family:, user:,
      metadata: { error_class: error.class.name, error_message: scrub_error(error.message).truncate(500), suggestion_id: id }
    )

    with_lock do
      next unless pending?

      update!(status: :failed, error: code)
    end
  end

  def ai_cancelled? = reload.cancelled?

  def ai_correlation_id = "recurring_transaction_suggestion:#{id}"

  def ai_finished(_count) = nil

  # The stored answer, re-normalized because JSON turns amounts back into
  # strings; nil until the job completes.
  def proposal
    return if result.blank?

    normalize(result)
  end

  # Applies only the add form's fields. A one-off keeps the entry's date; a
  # guessed monthly date is only useful for a repeating bill.
  def apply_to(recurring_transaction)
    answer = proposal
    return recurring_transaction if answer.nil?

    recurring_transaction.name = answer.name if answer.name.present?
    recurring_transaction.amount = answer.amount if answer.amount.present?
    recurring_transaction.frequency_preset = answer.frequency if answer.frequency.present?
    recurring_transaction.autopay = answer.autopay unless answer.autopay.nil?

    today = Date.current
    if answer.frequency == RecurringTransaction::FrequencyPreset::ONCE
      recurring_transaction.first_due_on = entry.date if entry
    elsif %w[weekly biweekly].include?(answer.frequency) && answer.weekday.present?
      recurring_transaction.first_due_on = today + ((answer.weekday - today.wday) % 7)
    elsif answer.frequency == "annual" && answer.month_of_year.present?
      recurring_transaction.first_due_on = next_annual_occurrence(
        today, answer.month_of_year, answer.day_of_month || recurring_transaction.first_due_on.day
      )
    elsif answer.day_of_month.present?
      recurring_transaction.first_due_on =
        RecurringTransaction::Schedule.new(expected_day_of_month: answer.day_of_month).next_occurrence_from_today
    end

    recurring_transaction
  end

  # The URL the broadcast frame reloads. A normal request renders the result
  # with a valid authenticity token; the frame's src is safe to fetch twice.
  def location
    if fill?
      Rails.application.routes.url_helpers.recurring_transactions_smart_fill_path(self)
    else
      Rails.application.routes.url_helpers.bill_smart_configuration_path(recurring_transaction_id, id)
    end
  end

  def broadcast_result
    target = ActionView::RecordIdentifier.dom_id(self)
    frame = ApplicationController.helpers.turbo_frame_tag(target, src: location)
    broadcast_replace_to self, target:, html: frame
  end

  # apply_ai and ai_failed run inside the generation job's transaction. Wait for
  # that transaction to commit before publishing a frame the browser will load,
  # and keep a cable failure from deciding whether the result was saved.
  def deliver_result_broadcast
    return unless saved_change_to_status? && (complete? || failed? || cancelled?)

    broadcast_result
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { feature: "bill_setup", suggestion_id: id })
  end

  private
    # Mirrors Current.accessible_entries: jobs have no Current, so the user's
    # current account shares decide whether the subject may still be read.
    def accessible_entries
      family.entries.joins(:account).merge(Account.accessible_by(user))
    end

    def scrub_error(message)
      scrubbed = Ai::Instrumentation::Redactor.scrub(message)
      ACCOUNT_IDENTIFIER_PATTERNS.reduce(scrubbed) { |text, pattern| text.gsub(pattern, Ai::Instrumentation::Redactor::MASK) }
    end

    def charges_from(entries)
      entries.first(MAX_CHARGES).map do |entry|
        { date: entry.date.iso8601, amount: entry.amount.abs.to_s, name: entry.name }
      end
    end

    # Same account, sign and name shape, newest first. A generic name (the
    # "Unknown transaction" fallback) would match unrelated entries.
    def evidence_entries(source)
      found = if source.generic_name?
        [ source ]
      else
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(source.name.to_s)}%"
        accessible_entries
          .where(entryable_type: "Transaction")
          .where(account_id: source.account_id)
          .where(income || source.amount.negative? ? "entries.amount < 0" : "entries.amount > 0")
          .where("entries.name ILIKE ?", pattern)
          .order(date: :desc)
          .limit(MAX_CHARGES)
          .to_a.presence || [ source ]
      end
      found
    end

    def current_config(series)
      return unless configure?

      detection = RecurringTransaction::FrequencyPreset.detect(series)
      {
        name: series.display_name,
        amount: series.amount.abs.to_s,
        # Only PRESETS are offered back; anything else reads as custom.
        frequency: detection.key.presence_in(RecurringTransaction::FrequencyPreset::PRESETS) || RecurringTransaction::FrequencyPreset::CUSTOM,
        day_of_month: detection.day_of_month,
        weekday: detection.weekday,
        month_of_year: detection.month_of_year,
        category: series.category&.name,
        bill_type: series.bill_type,
        autopay: series.autopay
      }.compact
    end

    # Ai::Schema already typed the fields; resolve the category locally, keep
    # only a positive amount and clamp the confidence.
    def normalize(raw)
      raw = raw.to_h.symbolize_keys
      category = resolve_category(raw[:category_name])

      amount = BigDecimal(raw[:amount].to_s) if raw[:amount].present?
      Proposal.new(
        **raw.slice(:name, :frequency, :day_of_month, :weekday, :month_of_year, :bill_type, :autopay, :rationale),
        amount: (amount if amount&.positive?),
        category_id: category&.id,
        category_name: category&.name,
        confidence: raw[:confidence]&.to_f&.clamp(0.0, 1.0)
      )
    end

    # This family's category or nothing: an LLM-invented name must never become
    # an id, and another family's category can never resolve here.
    def resolve_category(name)
      return nil if name.blank?

      family.categories.find_by(name: name) ||
        family.categories.find_by(Category.arel_table[:name].lower.eq(name.downcase))
    end

    # The next date landing on (month, day), clamped to the month's length and
    # rolled a year forward once this year's is past.
    def next_annual_occurrence(today, month, day)
      candidate = Date.new(today.year, month, [ day, Date.new(today.year, month, -1).day ].min)
      return candidate if candidate >= today

      Date.new(today.year + 1, month, [ day, Date.new(today.year + 1, month, -1).day ].min)
    end
end
