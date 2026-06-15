class Account::OpeningBalanceManager
  Result = Struct.new(:success?, :changes_made?, :error, keyword_init: true)

  def initialize(account)
    @account = account
  end

  def has_opening_anchor?
    opening_anchor_valuation.present?
  end

  # Most accounts should have an opening anchor. If not, we derive the opening date from the oldest entry date
  def opening_date
    return opening_anchor_valuation.entry.date if opening_anchor_valuation.present?

    [
      account.entries.valuations.order(:date).first&.date,
      account.entries.where.not(entryable_type: "Valuation").order(:date).first&.date&.prev_day
    ].compact.min || Date.current
  end

  def opening_balance
    opening_anchor_valuation&.entry&.amount || 0
  end

  # Keeps the opening anchor strictly before all activity.
  #
  # The balance engine only calculates forward from the opening anchor
  # (current_anchor_date.downto(opening_anchor_date)), so any entry dated on or
  # before the opening anchor would be invisible to the balance curve. When such
  # activity is recorded we backdate the opening anchor to before it and
  # preserve the previously-stated opening balance as a manual reconciliation
  # ("manual value update") on its original date, so the known balance is not
  # lost.
  #
  # Convert-once: only a meaningful (non-zero) opening balance is preserved as a
  # reconciliation. The replacement opening anchor starts at 0 ("balance unknown
  # before the earliest activity"), so subsequent earlier activity simply slides
  # that zero anchor further back without spawning duplicate reconciliations.
  def backdate_for_activity(activity_date)
    return Result.new(success?: true, changes_made?: false, error: nil) if opening_anchor_valuation.nil?

    anchor_entry = opening_anchor_valuation.entry
    return Result.new(success?: true, changes_made?: false, error: nil) if activity_date > anchor_entry.date

    ActiveRecord::Base.transaction do
      new_opening_date = available_opening_date_before(activity_date, excluding: anchor_entry)

      if anchor_entry.amount.zero?
        # Auto-created (or genuinely zero) opening anchor — just slide it earlier.
        anchor_entry.update!(date: new_opening_date)
      else
        # Preserve the originally-stated opening balance as a manual value update
        # on its original date, then start a fresh zero opening anchor before the
        # new activity.
        opening_anchor_valuation.update!(kind: "reconciliation")
        anchor_entry.update!(name: Valuation.build_reconciliation_name(account.accountable_type))
        create_opening_anchor(balance: 0, date: new_opening_date)
      end
    end

    @opening_anchor_valuation = nil # bust memo; kind/date changed above
    Result.new(success?: true, changes_made?: true, error: nil)
  end

  def set_opening_balance(balance:, date: nil)
    resolved_date = date || default_date

    # Validate date is before oldest entry
    if date && oldest_entry_date && resolved_date >= oldest_entry_date
      return Result.new(success?: false, changes_made?: false, error: "Opening balance date must be before the oldest entry date")
    end

    if opening_anchor_valuation.nil?
      create_opening_anchor(
        balance: balance,
        date: resolved_date
      )
      Result.new(success?: true, changes_made?: true, error: nil)
    else
      changes_made = update_opening_anchor(balance: balance, date: date)
      Result.new(success?: true, changes_made?: changes_made, error: nil)
    end
  end

  private
    attr_reader :account

    def opening_anchor_valuation
      @opening_anchor_valuation ||= account.valuations.opening_anchor.includes(:entry).first
    end

    def oldest_entry_date
      if opening_anchor_valuation&.entry
        account.entries.where.not(id: opening_anchor_valuation.entry.id).minimum(:date)
      else
        account.entries.minimum(:date)
      end
    end

    def default_date
      if oldest_entry_date
        [ oldest_entry_date - 1.day, 2.years.ago.to_date ].min
      else
        2.years.ago.to_date
      end
    end

    # The opening anchor must sit before the activity. Valuations are unique per
    # account+date, so step back past any existing valuation (e.g. the
    # reconciliation we just preserved) on the target date.
    def available_opening_date_before(activity_date, excluding:)
      candidate = activity_date - 1.day
      while account.entries.valuations.where(date: candidate).where.not(id: excluding.id).exists?
        candidate -= 1.day
      end
      candidate
    end

    def create_opening_anchor(balance:, date:)
      account.entries.create!(
        date: date,
        name: Valuation.build_opening_anchor_name(account.accountable_type),
        amount: balance,
        currency: account.currency,
        entryable: Valuation.new(
          kind: "opening_anchor"
        )
      )
    end

    def update_opening_anchor(balance:, date: nil)
      changes_made = false

      ActiveRecord::Base.transaction do
        # Update associated entry attributes
        entry = opening_anchor_valuation.entry

        if entry.amount != balance
          entry.amount = balance
          changes_made = true
        end

        if date.present? && entry.date != date
          entry.date = date
          changes_made = true
        end

        entry.save! if entry.changed?
      end

      changes_made
    end
end
