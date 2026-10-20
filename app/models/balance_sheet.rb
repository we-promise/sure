class BalanceSheet
  include Monetizable

  monetize :net_worth

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
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
      @account_totals ||= AccountTotals.new(family, user: user, sync_status_monitor: sync_status_monitor)
    end

    def net_worth_series_builder
      @net_worth_series_builder ||= NetWorthSeriesBuilder.new(family, user: user)
    end

    def sorted(accounts)
      account_order = user&.account_order
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
      when "manual"
        sort_manually(accounts)
      else
        accounts
      end
    end

    # Accounts the user has dragged into place come first, in their saved
    # position within their group; accounts added since then follow
    # alphabetically.
    def sort_manually(accounts)
      positions = user.manual_account_order.values.flat_map { |ids| ids.each_with_index.to_a }.to_h

      accounts.sort_by do |account|
        position = positions[account.id]
        [ position ? 0 : 1, position || 0, account.name.to_s.downcase ]
      end
    end
end
