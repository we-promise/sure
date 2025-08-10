class BalanceSheet
  include Monetizable

  monetize :net_worth

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def assets
    @assets ||= ClassificationGroup.new(
      classification: "asset",
      currency: family.currency,
      accounts: sorted(account_totals.asset_accounts)
    )
  end

  def liabilities
    @liabilities ||= ClassificationGroup.new(
      classification: "liability",
      currency: family.currency,
      accounts: sorted(account_totals.liability_accounts)
    )
  end

  def classification_groups
    [ assets, liabilities ]
  end

  def account_groups
    [ assets.account_groups, liabilities.account_groups ].flatten
  end

  def net_worth
    assets.total - liabilities.total
  end

  def net_worth_series(period: Period.last_30_days)
    net_worth_series_builder.net_worth_series(period: period)
  end

  def currency
    family.currency
  end

  def syncing?
    sync_status_monitor.syncing?
  end

  private
    def sync_status_monitor
      @sync_status_monitor ||= SyncStatusMonitor.new(family)
    end

    def account_totals
      @account_totals ||= AccountTotals.new(family, sync_status_monitor: sync_status_monitor)
    end

    def net_worth_series_builder
      @net_worth_series_builder ||= NetWorthSeriesBuilder.new(family)
    end

    def sorted(accounts)
      account_order = Current.user&.account_order
      order_key = account_order&.key || "name_asc"

      case order_key
      when "name_asc"
        accounts.sort_by(&:name)
      when "name_desc"
        accounts.sort_by(&:name).reverse
      when "balance_asc"
        accounts.sort_by(&:balance)
      when "balance_desc"
        accounts.sort_by(&:balance).reverse
      else
        accounts
      end
    end
end
