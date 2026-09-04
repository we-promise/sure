# Inherits RecurringTransactionsController so the re-rendered "new" template
# resolves its relative partials ("form") against recurring_transactions/.
class RecurringTransactions::SmartFillsController < RecurringTransactionsController
  include BillsHelper
  include RecurringFeatureGuardable

  guard_feature unless: -> { bills_one_shot_ai_available? }
  before_action :ensure_recurring_enabled

  # Smart-fill re-renders the add-bill dialog with AI-proposed values. It only
  # exists on the entry-prefilled variant: the picked transaction anchors the
  # evidence (its charge history), so the model infers rather than guesses --
  # cadence from date gaps, the due day, autopay markers. Synchronous: one
  # small LLM call, the same latency class as the identify action (slow local
  # models may want a generous request timeout).
  def create
    income = params[:income].present?
    @recurring_transaction = Current.family.recurring_transactions.new(
      frequency_preset: income ? "biweekly" : "monthly",
      first_due_on: Date.current
    )
    @recurring_transaction.is_income = income

    entry = Current.accessible_entries.find_by(id: params[:entry_id])

    if entry.nil?
      @smart_fill_error = t(".failed")
      return render "recurring_transactions/new", layout: dialog_layout
    end

    prefill_recurring_from_entry(entry)

    begin
      suggestion = RecurringTransaction::AiSetupSuggester
                     .new(Current.family, user: Current.user)
                     .suggest_from_entries(evidence_entries(entry, income: income))
      apply_suggestion(suggestion)
      @smart_fill = suggestion
    rescue RecurringTransaction::AiSetupSuggester::Error => e
      Rails.logger.warn("Smart fill failed for entry #{entry.id}: #{e.class}: #{e.message}")
      @smart_fill_error = t(".failed")
    end

    render "recurring_transactions/new", layout: dialog_layout
  end

  private
    # The picked entry's own history: same account, same sign, same name
    # shape. Recency-ordered so drifting amounts weight toward the present.
    def evidence_entries(entry, income:)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(entry.name.to_s)}%"

      entry.account.entries
           .where(entryable_type: "Transaction")
           .where(income || entry.amount.negative? ? "entries.amount < 0" : "entries.amount > 0")
           .where("entries.name ILIKE ?", pattern)
           .order(date: :desc)
           .limit(RecurringTransaction::AiSetupSuggester::MAX_CHARGES)
           .to_a
           .presence || [ entry ]
    end

    # Only fields the add form actually carries; anything else the suggestion
    # knows (category, kind) has no field to land in here and is dropped.
    # The due date follows the cadence's own anchor: weekday for weekly-style
    # presets, month for annual, day-of-month for the monthly-style rest.
    def apply_suggestion(suggestion)
      @recurring_transaction.name = suggestion.name if suggestion.name.present?
      @recurring_transaction.amount = suggestion.amount if suggestion.amount.present?
      @recurring_transaction.frequency_preset = suggestion.frequency if suggestion.frequency.present?
      @recurring_transaction.autopay = suggestion.autopay unless suggestion.autopay.nil?

      today = Date.current
      if %w[weekly biweekly].include?(suggestion.frequency) && suggestion.weekday.present?
        @recurring_transaction.first_due_on = today + ((suggestion.weekday - today.wday) % 7)
      elsif suggestion.frequency == "annual" && suggestion.month_of_year.present?
        @recurring_transaction.first_due_on = next_annual_occurrence(
          today, suggestion.month_of_year,
          suggestion.day_of_month || @recurring_transaction.first_due_on.day
        )
      elsif suggestion.day_of_month.present?
        @recurring_transaction.first_due_on =
          RecurringTransaction::Schedule.new(expected_day_of_month: suggestion.day_of_month).next_occurrence_from_today
      end
    end

    # The next date landing on (month, day), day clamped to the month's
    # length, rolled a year forward once this year's is past.
    def next_annual_occurrence(today, month, day)
      candidate = Date.new(today.year, month, [ day, Date.new(today.year, month, -1).day ].min)
      return candidate if candidate >= today

      Date.new(today.year + 1, month, [ day, Date.new(today.year + 1, month, -1).day ].min)
    end
end
