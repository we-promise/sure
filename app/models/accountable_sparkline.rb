# The sidebar sparkline of one account group, over the accounts the current user sees there.
class AccountableSparkline
  # #version of several groups, reading their account rows in one query.
  def self.versions(accountables)
    rows = scope.where(accountable_type: accountables.map(&:name))
      .left_outer_joins(:account_providers)
      .pluck(:accountable_type, *identity_columns)
      .group_by(&:first)

    accountables.to_h do |accountable|
      identity_rows = rows.fetch(accountable.name, []).map { |row| row.drop(1) }
      [ accountable, new(accountable, account_identity_rows: identity_rows).version ]
    end
  end

  # Per account: its identity (id and any provider link) and the share the
  # current user counts (Account.viewer_percentage_sql), read in the same
  # query as the rows.
  def self.identity_columns
    viewer = Account.connection.quote(Current.user.id)
    [
      :id, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id"),
      Arel.sql(Account.viewer_percentage_sql(viewer))
    ]
  end

  # Same accounts the sidebar group total sums: accessible to the current
  # user, visible, included in reports and counted in their finances (owned,
  # or shared with include_in_finances).
  def self.scope
    Current.accessible_accounts.visible.included_in_reports.included_in_finances_for(Current.user)
  end

  def initialize(accountable, account_identity_rows: nil)
    @accountable = accountable
    @account_identity_rows = account_identity_rows
  end

  def series
    Rails.cache.fetch(cache_key, expires_in: 24.hours) { build_series }
  end

  # Changes whenever the sparkline does; the sidebar puts it in the frame URL.
  def version
    Digest::SHA256.hexdigest("#{cache_key}_#{I18n.locale}").first(16)
  end

  # The series is built from exactly these account rows, scaled to the viewer's
  # ownership share of each, so the key carries a digest of both. A share
  # count/timestamp version can stay the same while the counted set changes
  # (ownership moved by update_all, shares replaced with older timestamps,
  # report exclusion toggled); the row digest changes whenever the set does
  # and never repeats for a different set. The percentages are in it too, so a
  # share edit changes #version and the browser fetches the new series.
  def cache_key
    @cache_key ||= family.build_cache_key(
      "#{@accountable.name}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}_#{Date.current}_#{account_rows_digest}",
      invalidate_on_data_updates: true
    )
  end

  private
    def family
      @family ||= Current.family
    end

    def account_scope
      @account_scope ||= self.class.scope.where(accountable_type: @accountable.name)
    end

    def account_ids
      @account_ids ||= account_identity_rows.map(&:first).uniq
    end

    def account_identity_rows
      @account_identity_rows ||= account_scope
        .left_outer_joins(:account_providers)
        .pluck(*self.class.identity_columns)
    end

    def build_series
      return aggregate_normalized_series if requires_normalized_aggregation?

      Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day",
        user: Current.user
      ).balance_series
    end

    # balance_type is derived purely from accountable_type, so only Investment/Crypto
    # can yield :investment. Short-circuit to avoid an N+1 `account.linked?` check
    # on every account for non-investment accountable types (loan, credit_card, etc).
    # The `Account.linked` scope is the SQL-level mirror of `Account#linked?`.
    def requires_normalized_aggregation?
      return false unless %w[Investment Crypto].include?(@accountable.name)

      account_identity_rows.any? do |_account_id, plaid_account_id, simplefin_account_id, account_provider_id, _percentage|
        plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?
      end
    end

    def aggregate_normalized_series
      Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day",
        user: Current.user
      )
    end

    # Rows are shared by everyone with the same accessible set, but the series
    # is not: a co-owner at 40% must never read the owner's 60% series, so each
    # row carries the viewer's percentage.
    def account_rows_digest
      Digest::SHA256.hexdigest(account_identity_rows.map { |row| row.join(":") }.sort.join(","))
    end
end
