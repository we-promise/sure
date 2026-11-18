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

  # The same accounts split by availability (Account::Liquidity), evaluated
  # on the family's "today" unless a date is given.
  def liquidity(date: Account.liquidity_today_for(family))
    @liquidity ||= {}
    @liquidity[date] ||= LiquidityOverview.new(
      asset_rows: account_totals.asset_accounts,
      liability_rows: account_totals.liability_accounts,
      currency: family.currency,
      date: date
    )
  end

  # Available net worth over time: release dates are evaluated per day with
  # today's classification.
  def available_net_worth_series(period: Period.last_30_days)
    net_worth_series_builder.available_net_worth_series(period: period)
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
        sort_by_name(accounts)
      when "name_desc"
        sort_by_name(accounts).reverse
      when "balance_asc"
        sort_by_balance(accounts)
      when "balance_desc"
        sort_by_balance(accounts).reverse
      when "manual"
        sort_manually(accounts)
      else
        accounts
      end
    end

    # Array#sort_by isn't stable, so accounts with an equal sort value could
    # swap places between renders; the id tie-break keeps the order fixed.
    def sort_by_name(accounts)
      accounts.sort_by { |account| [ account.name.to_s.downcase, account.id ] }
    end

    def sort_by_balance(accounts)
      accounts.sort_by { |account| [ account.converted_balance, account.id ] }
    end

    # Accounts the user has dragged into place come first, in their saved
    # position within their group; accounts added since then follow
    # alphabetically.
    def sort_manually(accounts)
      positions = user.manual_account_order.values.flat_map { |ids| ids.each_with_index.to_a }.to_h

      accounts.sort_by do |account|
        position = positions[account.id]
        [ position ? 0 : 1, position || 0, account.name.to_s.downcase, account.id.to_s ]
      end
    end
end
