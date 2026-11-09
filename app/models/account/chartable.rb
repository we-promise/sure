module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v4"

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  # Returns the chart Series for this account over the given period.
  # Supported views: :balance, :cash_balance, :holdings_balance, :gains.
  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance, :gains ].include?(view.to_sym)

    @balance_series ||= {}

    memo_key = [ period.start_date, period.end_date, interval ].compact.join("_")

    builder = (@balance_series[memo_key] ||= Balance::ChartSeriesBuilder.new(
      account_ids: [ id ],
      currency: self.currency,
      period: period,
      favorable_direction: favorable_direction,
      interval: interval
    ))

    normalize_linked_investment_series(builder.send("#{view}_series"), view: view)
  end

  def sparkline_series
    Rails.cache.fetch(sparkline_cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  # Built from this account's own data, so a sync of another account keeps it cached.
  # Investment series are normalized from holdings and entries that can change outside
  # this account's syncs, so those keep the family-wide sync timestamp.
  def sparkline_cache_key
    @sparkline_cache_key ||= sparkline_cache_key_from(
      balances_version: self.class.rows_version(balances.pick(*self.class.rows_version_columns(Balance))),
      providers_version: self.class.rows_version(account_providers.pick(*self.class.rows_version_columns(AccountProvider))),
      last_synced_at: last_synced_at
    )
  end

  def sparkline_cache_key_from(balances_version:, providers_version:, last_synced_at:)
    [
      "account_sparkline", SPARKLINE_CACHE_VERSION, id, updated_at.to_f, last_synced_at&.to_f,
      balances_version, providers_version, Date.current,
      (family.latest_sync_completed_at&.to_f if balance_type == :investment)
    ].join("_")
  end

  # Changes whenever the sparkline does; the sidebar puts it in the frame URL.
  def sparkline_version
    self.class.sparkline_version_for(sparkline_cache_key)
  end

  class_methods do
    # #sparkline_version of many accounts from three grouped queries instead of three per account.
    def sparkline_versions(accounts)
      ids = accounts.map(&:id)
      balances = Balance.where(account_id: ids).group(:account_id).pluck(:account_id, *rows_version_columns(Balance))
      providers = AccountProvider.where(account_id: ids).group(:account_id).pluck(:account_id, *rows_version_columns(AccountProvider))
      balances = balances.to_h { |id, *version| [ id, rows_version(version) ] }
      providers = providers.to_h { |id, *version| [ id, rows_version(version) ] }
      synced = Sync.latest_completed_by_syncable(accounts)

      accounts.to_h do |account|
        key = account.sparkline_cache_key_from(
          balances_version: balances.fetch(account.id) { rows_version([ 0, nil ]) },
          providers_version: providers.fetch(account.id) { rows_version([ 0, nil ]) },
          last_synced_at: synced[[ account.class.base_class.name, account.id ]]&.completed_at
        )
        [ account.id, sparkline_version_for(key) ]
      end
    end

    def sparkline_version_for(cache_key)
      Digest::SHA256.hexdigest("#{cache_key}_#{I18n.locale}").first(16)
    end

    def rows_version_columns(model)
      [ Arel.sql("count(*)"), Arel.sql("max(#{model.table_name}.updated_at)") ]
    end

    def rows_version(count_and_max_updated_at)
      count_and_max_updated_at.map { |v| v&.to_f }.join("-")
    end
  end

  private
    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
