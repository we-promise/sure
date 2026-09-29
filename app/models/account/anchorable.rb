# All accounts are "anchored" with start/end valuation records, with transactions,
# trades, and reconciliations between them.
module Account::Anchorable
  extend ActiveSupport::Concern

  included do
    include Monetizable

    monetize :opening_balance
  end

  def set_opening_anchor_balance(**opts)
    result = opening_balance_manager.set_opening_balance(**opts)
    sync_later if result.success?
    result
  end

  def opening_anchor_date
    opening_balance_manager.opening_date
  end

  def opening_anchor_balance
    opening_balance_manager.opening_balance
  end

  def has_opening_anchor?
    opening_balance_manager.has_opening_anchor?
  end

  # Keep manual history visible when a linked provider publishes only positions.
  def history_start_date
    if linked? && balance_type == :investment && !position_tracking?
      Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(self)
    else
      [
        (opening_anchor_date if has_opening_anchor?),
        entries.excluding_pending.minimum(:date),
        balances.minimum(:date)
      ].compact.min
    end
  end

  # Distinguish imported totals from manual valuations; providers that schedule
  # their own account sync can defer it until all related accounts are processed.
  def set_current_balance(balance, provider_balance: false, schedule_sync: true)
    result = current_balance_manager.set_current_balance(balance, provider_balance: provider_balance)
    sync_later if schedule_sync && result.success?
    result
  end

  def current_anchor_balance
    current_balance_manager.current_balance
  end

  def current_anchor_date
    current_balance_manager.current_date
  end

  def has_current_anchor?
    current_balance_manager.has_current_anchor?
  end

  # The first cash-only anchor opts this account into shared forward accounting.
  def accounting_start_date
    entries.valuations.where(entryable_id: Valuation.cash_anchor.select(:id)).minimum(:date)
  end

  # Retain earlier imported history, while explicit edits may rebuild it.
  def materialization_window(window_start_date = nil)
    return window_start_date unless accounting_start_date

    window_start_date || balances.where(currency: currency).maximum(:date) || accounting_start_date
  end

  # Capture cash and its ledger baseline without reapplying earlier transactions.
  # Same-day total valuations yield to this new anchor until explicitly edited.
  def create_cash_anchor!
    entry = entries.valuations.find_by(date: Date.current, entryable_id: Valuation.cash_anchor.select(:id)) ||
      entries.new(date: Date.current, entryable: Valuation.new(kind: :cash_anchor))
    entry.assign_attributes(amount: cash_balance, currency: currency, name: I18n.t("valuations.cash_anchor", locale: family.locale))
    entry.entryable.cash_entry_total = Balance::SyncCache.new(self).cash_entry_total(Date.current)
    entry.save!
    valuations.where.not(kind: "cash_anchor").joins(:entry).where(entries: { date: Date.current }).update_all(superseded_at: Time.current)
    entry
  end

  # A full provider reports cash independently of the position publishers.
  # Its ledger baseline is captured after all imported entries are available.
  def apply_provider_balance!(balance:, cash_balance:, **attributes)
    return update!(balance: balance, cash_balance: cash_balance, **attributes) unless accounting_start_date

    update!(attributes) if attributes.any?
    entry = entries.valuations.find_by(date: Date.current, entryable_id: Valuation.cash_anchor.select(:id)) ||
      entries.new(date: Date.current, entryable: Valuation.new(kind: :cash_anchor))
    entry.assign_attributes(amount: cash_balance, currency: currency, source: "provider_cash",
      name: I18n.t("valuations.cash_anchor", locale: family.locale))
    entry.entryable.cash_entry_total = nil
    entry.save!
    valuations.where.not(kind: "cash_anchor").joins(:entry).where(entries: { date: Date.current }).update_all(superseded_at: Time.current)
    entry
  end

  # Provider import can replace the anchor while retaining this account instance.
  def reset_current_anchor_cache!
    @current_balance_manager = nil
  end

  private
    def opening_balance_manager
      @opening_balance_manager ||= Account::OpeningBalanceManager.new(self)
    end

    def current_balance_manager
      @current_balance_manager ||= Account::CurrentBalanceManager.new(self)
    end
end
