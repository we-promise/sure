class SaxoItem::Importer
  def initialize(item)
    @item = item
    @provider = item.saxo_provider
  end

  def import(sync)
    accounts = @provider.accounts
    identifiers = accounts.map { |raw| raw.fetch("AccountId") }
    raise Provider::Saxo::Error, "Saxo returned duplicate accounts" unless identifiers.uniq.length == identifiers.length
    accounts.each do |raw|
      raise Provider::Saxo::Error, "Saxo account is incomplete" unless %w[AccountId AccountKey ClientKey Currency].all? { |key| raw[key].present? }
      @item.saxo_accounts.find_or_initialize_by(account_id: raw.fetch("AccountId")).update!(
        name: raw["DisplayName"].presence || "Saxo #{raw['AccountId']}",
        currency: raw.fetch("Currency"),
        account_type: raw["AccountSubType"],
        raw_payload: raw,
        opening_date: raw["CreationDate"].present? ? Provider::Saxo::Normalizer.date(raw["CreationDate"]) : nil
      )
    end
    linked = @item.saxo_accounts.joins(:account_provider).includes(:account_provider, :account)
    staged = linked.map do |account|
      raise Provider::Saxo::Error, "A linked Saxo account is missing" unless identifiers.include?(account.account_id)
      unless account.currency == account.account.currency
        raise Provider::Saxo::Error.new("Saxo account currency differs from the linked account", diagnostic: {
          stage: "accounts", reason: "currency_mismatch", account_provider_id: account.account_provider.id
        })
      end
      raw = account.raw_payload
      balance = @provider.balances(raw)
      unless balance["Currency"] == account.currency && SaxoAccount::Processor::ACCEPTED_CALCULATION_RELIABILITY.include?(balance["CalculationReliability"])
        raise Provider::Saxo::Error, "Saxo balance currency or reliability is invalid"
      end
      total = Provider::Saxo::Normalizer.decimal(balance["TotalValue"])
      cash = Provider::Saxo::Normalizer.decimal(balance["CashBalance"])
      positions = @provider.positions(raw)
      since = if sync.window_start_date
        [ sync.window_start_date, @item.sync_start_date ].max
      elsif account.history_synced_on
        [ account.history_synced_on - 60, @item.sync_start_date ].max
      else
        @item.sync_start_date
      end
      rows = @provider.history(raw, since: since, until_date: [ sync.window_end_date || Date.current, Date.current ].min)
      normalized = normalize_history(account, rows)
      processor = SaxoAccount::Processor.new(account)
      holdings = processor.normalize_positions(positions)
      [ account, total, cash, positions, rows, normalized, holdings ]
    end
    # Every linked account is validated before any financial record is changed.
    ApplicationRecord.transaction do
      staged.each do |account, total, cash, positions, rows, normalized, holdings|
        account.update!(
          current_balance: total,
          cash_balance: cash,
          raw_holdings_payload: positions,
          raw_transactions_payload: rows
        )
        SaxoAccount::Processor.new(account).process(normalized, holdings)
        account.update!(history_synced_on: Date.current)
      end
      @item.update!(pending_account_setup: @item.unlinked_accounts_count.positive?)
    end
    linked.each do |provider_account|
      provider_account.account.sync_later(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end
    @item.family.auto_match_transfers!
  end

  private
    def normalize_history(account, rows)
      Provider::Saxo::Normalizer.new(account_id: account.account_id, currency: account.currency).call(rows)
    rescue Provider::Saxo::Error => error
      error.diagnostic[:account_provider_id] = account.account_provider.id
      raise
    end
end
