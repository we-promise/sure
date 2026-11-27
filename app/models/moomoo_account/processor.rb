class MoomooAccount::Processor
  attr_reader :moomoo_account

  def initialize(moomoo_account)
    @moomoo_account = moomoo_account
  end

  def process
    return unless account.present? && moomoo_account.linkable?
    return if moomoo_account.snapshot_stale?

    if MoomooAccount::CashAccountConversion.new(moomoo_account).convert
      @account = moomoo_account.reload.current_account
    end
    MoomooAccount::CurrencyRouter.new(moomoo_account).route! if moomoo_account.split_by_currency?
    holdings = MoomooAccount::HoldingsProcessor.new(moomoo_account, date: snapshot_date).process
    update_account_balance!(holdings)
    MoomooAccount::ReconciliationRestatement.new(moomoo_account).process
    MoomooAccount::ActivitiesProcessor.new(moomoo_account).process
    MoomooAccount::CashLogsProcessor.new(moomoo_account).process
    MoomooAccount::TradeSettlements.new(moomoo_account).process
    account.ensure_opening_anchor_precedes_entries

    account.broadcast_sync_complete
  end

  private

    def account
      @account ||= moomoo_account.current_account
    end

    # The day moomoo's figures describe. An account moomoo no longer shares,
    # or whose funds a sync could not use, keeps the date of its last
    # snapshot, so its old figures are never restated as today's.
    def snapshot_date
      @snapshot_date ||= [ moomoo_account.source_account.last_positions_sync&.to_date, Date.current ].compact.min
    end

    # The total is moomoo's own, or for an account split by currency its
    # row's share (see MoomooAccount::CurrencySplit): a cash row's cash, a
    # stocks row's positions, never the cash of a cash row not set up yet.
    # Cash is what the imported holdings don't account for, so skipped
    # positions, futures and FX count as cash and the total stays equal to
    # moomoo's.
    def update_account_balance!(holdings)
      total = moomoo_account.current_balance
      return if total.nil?

      account.update!(currency: moomoo_account.currency) if account.currency != moomoo_account.currency

      result = account.set_current_balance(total, date: snapshot_date, schedule_sync: false)
      raise Provider::Moomoo::MoomooError.new("Failed to set the current balance: #{result.error}", :processing_failed) unless result.success?

      # A snapshot older than the anchor describes a day gone by.
      account.update!(cash_balance: cash_balance(total, holdings)) unless result.historical?
    end

    def cash_balance(total, holdings)
      total - holdings.sum(BigDecimal("0")) do |holding|
        Money.new(holding[:amount], holding[:currency]).exchange_to(moomoo_account.currency, date: snapshot_date).amount
      end
    rescue Money::ConversionError => e
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "MoomooAccount::Processor - FX conversion failed (#{e.from_currency}->#{e.to_currency}); using moomoo cash",
        source: "moomoo",
        provider_key: "moomoo",
        family: moomoo_account.moomoo_item.family,
        account_provider: moomoo_account.account_provider,
        metadata: { moomoo_account_id: moomoo_account.id }
      )
      moomoo_account.cash_balance || 0
    end
end
