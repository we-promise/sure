# The sidebar sparkline of one account group, over the accounts the current user sees there.
class AccountableSparkline
  IDENTITY_COLUMNS = [ :id, :plaid_account_id, :simplefin_account_id, Arel.sql("account_providers.id") ].freeze

  # #version of several groups, reading their account rows in one query.
  def self.versions(accountables)
    rows = scope.where(accountable_type: accountables.map(&:name))
      .left_outer_joins(:account_providers)
      .pluck(:accountable_type, *IDENTITY_COLUMNS)
      .group_by(&:first)

    accountables.to_h do |accountable|
      identity_rows = rows.fetch(accountable.name, []).map { |row| row.drop(1) }
      [ accountable, new(accountable, account_identity_rows: identity_rows).version ]
    end
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

  # The series is built from exactly these account rows, so the key carries a
  # digest of them. A share count/timestamp version can stay the same while
  # the counted set changes (ownership moved by update_all, shares replaced
  # with older timestamps, report exclusion toggled); the row digest changes
  # whenever the set does and never repeats for a different set.
  def cache_key
    @cache_key ||= family.build_cache_key(
      "#{@accountable.name}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}_#{account_rows_digest}",
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
        .pluck(*IDENTITY_COLUMNS)
    end

    def build_series
      return aggregate_normalized_series if requires_normalized_aggregation?

      Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day"
      ).balance_series
    end

    # balance_type is derived purely from accountable_type, so only Investment/Crypto
    # can yield :investment. Short-circuit to avoid an N+1 `account.linked?` check
    # on every account for non-investment accountable types (loan, credit_card, etc).
    # The `Account.linked` scope is the SQL-level mirror of `Account#linked?`.
    def requires_normalized_aggregation?
      return false unless %w[Investment Crypto].include?(@accountable.name)

      account_identity_rows.any? do |_account_id, plaid_account_id, simplefin_account_id, account_provider_id|
        plaid_account_id.present? || simplefin_account_id.present? || account_provider_id.present?
      end
    end

    def aggregate_normalized_series
      Balance::LinkedInvestmentSeriesNormalizer.aggregate_account_ids(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day"
      )
    end

    def account_rows_digest
      Digest::SHA256.hexdigest(account_identity_rows.map { |row| row.join(":") }.sort.join(","))
    end
end
