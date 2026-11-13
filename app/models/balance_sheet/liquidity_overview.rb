# The balance sheet split by availability (Account::Liquidity): how much of
# the family's wealth can be reached at short notice, how much is locked, and
# when the locked money is released.
#
# Built from the balance sheet's account rows, so it sees the same accounts
# (visible, shared with the viewer, included in their finances, not excluded
# from reports) and the same converted balances as the net worth figures.
#
# - available assets: assets that are available on `date`
# - bound assets: the rest of the assets
# - short-term liabilities: credit cards and overdraft lines
# - available net worth: available assets minus short-term liabilities
class BalanceSheet::LiquidityOverview
  # Release timeline buckets, in display order. Locked accounts land in the
  # first bucket whose horizon (in months) their next release date fits;
  # locked accounts without a date and long-term accounts get their own.
  RELEASE_HORIZONS = { "within_3_months" => 3, "within_12_months" => 12, "within_36_months" => 36 }.freeze
  BUCKETS = (RELEASE_HORIZONS.keys + %w[later no_date long_term]).freeze

  Level = Data.define(:key, :total, :weight, :accounts)
  Release = Data.define(:account, :amount, :date, :days, :auto_renew)
  Bucket = Data.define(:key, :total, :releases)

  attr_reader :currency, :date

  def initialize(asset_rows:, liability_rows:, currency:, date:)
    @asset_rows = counted(asset_rows)
    @liability_rows = counted(liability_rows)
    @currency = currency
    @date = date
  end

  def available_assets
    money(available_rows.sum(&:converted_balance))
  end

  def bound_assets
    money(bound_rows.sum(&:converted_balance))
  end

  def short_term_liabilities
    money(short_term_liability_rows.sum(&:converted_balance))
  end

  def available_net_worth
    available_assets - short_term_liabilities
  end

  def total_assets
    money(asset_rows.sum(&:converted_balance))
  end

  # Share of the assets that is available, in percent (0 without assets).
  def available_share
    share(available_assets.amount)
  end

  def bound_share
    share(bound_assets.amount)
  end

  # Assets grouped by the level that applies on `date` (a released locked
  # account reads as immediate), in Account::Liquidity::LEVELS order. Levels
  # without accounts are left out.
  def asset_levels
    @asset_levels ||= Account::Liquidity::LEVELS.filter_map do |level|
      rows = asset_rows.select { |row| row.effective_liquidity(date) == level }
      next if rows.empty?

      total = rows.sum(&:converted_balance)
      Level.new(key: level, total: money(total), weight: share(total), accounts: rows)
    end
  end

  def short_term_liability_rows
    @short_term_liability_rows ||= liability_rows.select { |row| row.liquidity.in?(Account::Liquidity::AVAILABLE_LEVELS) }
  end

  # Locked money by when it is released, in BUCKETS order. Empty buckets stay
  # in so the timeline keeps its shape; the view decides what to draw.
  def release_buckets
    @release_buckets ||= begin
      grouped = Hash.new { |hash, key| hash[key] = [] }
      releases.each { |release| grouped[bucket_for(release.date)] << release }
      grouped["no_date"].concat(undated_locked_rows.map { |row| release_for(row, nil) })
      grouped["long_term"].concat(long_term_rows.map { |row| release_for(row, nil) })

      BUCKETS.map do |key|
        Bucket.new(key: key, total: money(grouped[key].sum { |release| release.amount.amount }), releases: grouped[key])
      end
    end
  end

  # Locked accounts that have a release date still to come, soonest first.
  def releases
    @releases ||= bound_rows
      .select { |row| row.liquidity == "locked" }
      .filter_map { |row| (release_date = row.next_release_date(date)) && release_for(row, release_date) }
      .sort_by { |release| [ release.date, release.account.name ] }
  end

  def releases_by_year
    releases.group_by { |release| release.date.year }
            .transform_values { |year_releases| money(year_releases.sum { |release| release.amount.amount }) }
  end

  def next_release
    releases.first
  end

  def bound?
    bound_rows.any?
  end

  def any?
    asset_rows.any? || short_term_liability_rows.any?
  end

  private
    attr_reader :asset_rows, :liability_rows

    # Same filter as the classification totals: accounts the viewer counts in
    # their finances and that are not excluded from reports.
    def counted(rows)
      rows.select { |row| row.respond_to?(:included_in_finances?) ? row.included_in_finances? : true }
          .reject { |row| row.respond_to?(:exclude_from_reports?) && row.exclude_from_reports? }
    end

    def available_rows
      @available_rows ||= asset_rows.select { |row| row.available_on?(date) }
    end

    def bound_rows
      @bound_rows ||= asset_rows - available_rows
    end

    def undated_locked_rows
      bound_rows.select { |row| row.liquidity == "locked" && row.next_release_date(date).nil? }
    end

    def long_term_rows
      bound_rows.select { |row| row.liquidity == "long_term" }
    end

    def release_for(row, release_date)
      Release.new(
        account: row,
        amount: money(row.converted_balance),
        date: release_date,
        days: release_date && (release_date - date).to_i,
        auto_renew: row.auto_renew?
      )
    end

    def bucket_for(release_date)
      RELEASE_HORIZONS.find { |_key, months| release_date <= (date >> months) }&.first || "later"
    end

    def share(amount)
      total = asset_rows.sum(&:converted_balance)
      return 0 unless total.positive?

      (amount.to_d / total * 100).round(1)
    end

    def money(amount)
      Money.new(amount, currency)
    end
end
