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
      @account_rows ||= query.map do |account_row|
        AccountRow.new(
          account: account_row,
          converted_balance: account_row.converted_balance,
          is_syncing: sync_status_monitor.account_syncing?(account_row)
        )
      end
    end

    def cache_key
      # Build a cache key that ONLY includes visible accounts' updated_at timestamps.
      # This prevents disabled accounts from affecting the cache key while the cached
      # data only contains visible accounts, which could cause stale data issues.
      visible_max_updated_at = family.accounts.visible.maximum(:updated_at)

      [
        family.id,
        "balance_sheet_account_rows",
        family.latest_sync_completed_at,
        visible_max_updated_at
      ].compact.join("_")
    end

    def query
      @query ||= Rails.cache.fetch(cache_key) do
        visible_accounts
          .joins(ActiveRecord::Base.sanitize_sql_array([
            "LEFT JOIN exchange_rates ON exchange_rates.date = ? AND accounts.currency = exchange_rates.from_currency AND exchange_rates.to_currency = ?",
            Date.current,
            family.currency
          ]))
          .select(
            "accounts.*",
            "SUM(accounts.balance * COALESCE(exchange_rates.rate, 1)) as converted_balance"
          )
          .group(:classification, :accountable_type, :id)
          .to_a
      end
    end
end
