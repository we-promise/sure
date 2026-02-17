class BalanceSheet::AccountTotals
  def initialize(family, sync_status_monitor:)
    @family = family
    @sync_status_monitor = sync_status_monitor
  end

  def asset_accounts
    @asset_accounts ||= account_rows.filter { |t| t.classification == "asset" }
  end

  def liability_accounts
    @liability_accounts ||= account_rows.filter { |t| t.classification == "liability" }
  end

  private
    attr_reader :family, :sync_status_monitor

    AccountRow = Data.define(:account, :converted_balance, :is_syncing) do
      def syncing? = is_syncing

      # Allows Rails path helpers to generate URLs from the wrapper
      def to_param = account.to_param
      delegate_missing_to :account
    end

    def visible_accounts
      @visible_accounts ||= family.accounts.visible.with_attached_logo
    end

    def account_rows
      @account_rows ||= cached_accounts.map do |account|
        AccountRow.new(
          account: account,
          converted_balance: converted_balance_for(account),
          is_syncing: sync_status_monitor.account_syncing?(account)
        )
      end
    end

    def cache_key
      family.build_cache_key(
        "balance_sheet_accounts",
        invalidate_on_data_updates: true
      )
    end

    def cached_accounts
      @cached_accounts ||= Rails.cache.fetch(cache_key) do
        visible_accounts.to_a
      end
    end

    def converted_balance_for(account)
      Money.new(account.balance, account.currency)
           .exchange_to(family.currency, date: Date.current, fallback_rate: 1)
           .amount
    end
end
