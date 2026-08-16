class Holding < ApplicationRecord
  include Monetizable, Gapfillable

  monetize :amount

  # Cost basis source priority (higher = takes precedence)
  COST_BASIS_SOURCE_PRIORITY = {
    nil => 0,
    "provider" => 1,
    "calculated" => 2,
    "manual" => 3
  }.freeze

  COST_BASIS_SOURCES = %w[manual calculated provider].freeze

  belongs_to :account
  belongs_to :security
  belongs_to :account_provider, optional: true
  belongs_to :provider_security, class_name: "Security", optional: true

  validates :qty, :currency, :date, :price, :amount, presence: true
  validates :qty, :price, :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :external_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :cost_basis_source, inclusion: { in: COST_BASIS_SOURCES }, allow_nil: true

  scope :chronological, -> { order(:date) }
  scope :for, ->(security) { where(security_id: security).order(:date) }
  scope :with_locked_cost_basis, -> { where(cost_basis_locked: true) }
  scope :with_unlocked_cost_basis, -> { where(cost_basis_locked: false) }
  # Non-provider rows that are not user-entered/locked cost basis.
  # Keep in sync with #calculated?
  scope :calculated, -> {
    where(account_provider_id: nil, cost_basis_locked: false)
      .where("cost_basis_source IS DISTINCT FROM ?", "manual")
  }

  # In-memory counterpart of .calculated — used on already-loaded rows.
  def calculated?
    account_provider_id.nil? && !cost_basis_locked? && cost_basis_source != "manual"
  end

  # Deterministic ORDER BY fragment for DISTINCT ON (... security_id) latest-row
  # selection when multiple currencies can exist on the same date.
  # Prefers non-zero qty (so neutralized orphan-currency cost-basis rows lose),
  # then provider rows, then a preferred currency (usually account currency),
  # then alphabetical currency for stability across syncs.
  def self.latest_security_order_sql(prefer_currency: nil, table: table_name, partition_columns: %w[security_id])
    parts = []
    parts.concat(partition_columns.map { |column| "#{table}.#{column}" }) if partition_columns.present?
    parts << "#{table}.date DESC"
    parts << "(#{table}.qty <> 0) DESC"
    parts << "(#{table}.account_provider_id IS NOT NULL) DESC"
    parts << sanitize_sql_array([ "(#{table}.currency = ?) DESC", prefer_currency ]) if prefer_currency.present?
    parts << "#{table}.currency ASC"
    parts.join(", ")
  end

  # In-memory twin of +latest_security_order_sql+ — pick one row from already-loaded
  # holdings when multiple currencies share the same security/date.
  def self.pick_latest_for_security(holdings, prefer_currency: nil)
    Array(holdings).min_by { |holding| latest_security_sort_key(holding, prefer_currency:) }
  end

  # Ascending sort key matching +latest_security_order_sql+ (lowest wins / first in SQL).
  def self.latest_security_sort_key(holding, prefer_currency: nil)
    prefer = prefer_currency.to_s
    currency = holding.currency.to_s

    [
      -holding.date.jd,
      holding.qty.to_d.zero? ? 1 : 0,
      holding.account_provider_id.present? ? 0 : 1,
      prefer.present? && currency == prefer ? 0 : 1,
      currency
    ]
  end

  delegate :ticker, to: :security

  def name
    security.name || ticker
  end

  def weight
    return nil unless amount
    return 0 if amount.zero?

    converted = amount_in_account_currency
    return nil if converted.nil?

    account.balance.zero? ? 1 : converted / account.balance * 100
  end

  # Returns average cost per share, or nil if unknown.
  #
  # Uses pre-computed cost_basis if available (set during materialization),
  # otherwise falls back to calculating from trades. Returns nil when cost
  # basis cannot be determined (no trades and no provider cost_basis).
  def avg_cost
    # Use stored cost_basis if available (eliminates N+1 queries)
    # - If locked (user-set), trust the value even if 0 (valid for airdrops)
    # - Otherwise require positive since providers sometimes return 0 when unknown
    if cost_basis.present?
      if cost_basis_locked? || cost_basis.positive?
        return Money.new(cost_basis, currency)
      end
    end

    # Fallback to calculation for holdings without pre-computed cost_basis
    calculate_avg_cost
  end

  def trend
    @trend ||= calculate_trend
  end

  # Day change based on previous holding snapshot (same account/security/currency)
  # Returns a Trend struct similar to other trend usages or nil if no prior snapshot.
  def day_change
    # Memoize even when nil to avoid repeated queries during a request lifecycle
    return @day_change if instance_variable_defined?(:@day_change)

    return (@day_change = nil) unless amount_money

    prev = account.holdings
                 .where(security_id: security_id, currency: currency)
                 .where("date < ?", date)
                 .order(date: :desc)
                 .first

    @day_change = prev&.amount_money ? Trend.new(current: amount_money, previous: prev.amount_money) : nil
  end

  def trades
    account.entries.where(entryable: account.trades.where(security: security)).reverse_chronological
  end

  def destroy_holding_and_entries!
    transaction do
      account.entries.where(entryable: account.trades.where(security: security)).destroy_all
      destroy
    end

    account.sync_later
  end

  # Returns the priority level for the current source (higher = better)
  def cost_basis_source_priority
    COST_BASIS_SOURCE_PRIORITY[cost_basis_source] || 0
  end

  # Check if this holding's cost_basis can be overwritten by the given source
  def cost_basis_replaceable_by?(new_source)
    return false if cost_basis_locked?

    new_priority = COST_BASIS_SOURCE_PRIORITY[new_source] || 0

    # Special case: when user unlocks a manual cost_basis, they're opting into
    # recalculation. Allow only "calculated" source to replace it (from trades).
    # This is the whole point of the unlock action.
    if cost_basis_source == "manual"
      return new_source == "calculated"
    end

    # Allow refreshes from the same source (e.g., new trades change calculated cost basis,
    # or providers send updated cost basis).
    new_priority >= cost_basis_source_priority
  end

  # Set cost_basis from user input (locks the value)
  def set_manual_cost_basis!(value)
    update!(
      cost_basis: value,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )
  end

  # Unlock cost_basis to allow provider/calculated updates
  def unlock_cost_basis!
    update!(cost_basis_locked: false)
  end

  # Check if this holding's security can be changed by provider sync
  def security_replaceable_by_provider?
    !security_locked?
  end

  # Check if user has remapped this holding to a different security
  # Also verifies the provider_security record still exists (FK should prevent deletion, but be safe)
  def security_remapped?
    provider_security_id.present? && security_id != provider_security_id && provider_security.present?
  end

  # Remap this holding (and all other holdings for the same security) to a different security
  # Also moves all trades for the old security to the new security
  # If the target security already has holdings on some dates, merge by combining qty/amount
  def remap_security!(new_security)
    return if new_security.id == security_id

    old_security = security

    transaction do
      # Find (date, currency) pairs where the new security already has holdings (collision keys)
      # Currency must match to merge - can't combine holdings denominated in different currencies
      collision_keys = account.holdings
        .where(security: new_security)
        .where(date: account.holdings.where(security: old_security).select(:date))
        .pluck(:date, :currency)
        .to_set

      # Process each holding for the old security
      account.holdings.where(security: old_security).find_each do |holding|
        if collision_keys.include?([ holding.date, holding.currency ])
          # Collision: merge into existing holding for new_security (same date AND currency)
          existing = account.holdings.find_by!(security: new_security, date: holding.date, currency: holding.currency)
          merged_qty = existing.qty + holding.qty
          merged_amount = existing.amount + holding.amount

          # Calculate weighted average cost basis if both holdings have cost_basis
          merged_cost_basis = if existing.cost_basis.present? && holding.cost_basis.present? && merged_qty.positive?
            ((existing.cost_basis * existing.qty) + (holding.cost_basis * holding.qty)) / merged_qty
          else
            existing.cost_basis # Keep existing if we can't calculate weighted average
          end

          # Preserve provider tracking from the holding being destroyed
          # so subsequent syncs can find the merged holding
          merge_attrs = {
            qty: merged_qty,
            amount: merged_amount,
            price: merged_qty.positive? ? merged_amount / merged_qty : 0,
            cost_basis: merged_cost_basis
          }
          merge_attrs[:external_id] ||= holding.external_id if existing.external_id.blank? && holding.external_id.present?
          merge_attrs[:provider_security_id] ||= holding.provider_security_id || old_security.id if existing.provider_security_id.blank?
          merge_attrs[:account_provider_id] ||= holding.account_provider_id if existing.account_provider_id.blank? && holding.account_provider_id.present?
          merge_attrs[:security_locked] = true # Lock merged holding to prevent provider overwrites

          existing.update!(merge_attrs)
          holding.destroy!
        else
          # No collision: update to new security
          holding.provider_security_id ||= old_security.id
          holding.security = new_security
          holding.security_locked = true
          holding.save!
        end
      end

      # Move all trades for old security to new security
      account.trades.where(security: old_security).update_all(security_id: new_security.id)
    end

    # Reload self to reflect changes (may raise RecordNotFound if self was destroyed)
    begin
      reload
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

  # Reset security (and all related holdings) back to what the provider originally sent
  # Note: This moves ALL trades for current_security back to original_security. If the user
  # had legitimate trades for the target security before remapping, those would also be moved.
  # In practice this is rare since SimpleFIN doesn't provide trades, and Plaid trades would
  # typically be for real tickers not CUSTOM: ones. A more robust solution would track which
  # trades were moved during remap, but that adds significant complexity for an edge case.
  def reset_security_to_provider!
    return unless provider_security_id.present?

    current_security = security
    original_security = provider_security

    # Guard against deleted provider_security (shouldn't happen due to FK, but be safe)
    return unless original_security.present?

    transaction do
      # Move trades back (see note above about limitation)
      account.trades.where(security: current_security).update_all(security_id: original_security.id)

      # Reset ALL holdings that were remapped from this provider_security
      account.holdings.where(security: current_security, provider_security: original_security).find_each do |holding|
        holding.update!(
          security: original_security,
          security_locked: false,
          provider_security_id: nil
        )
      end
    end

    # Reload self to reflect changes
    reload
  end

  # Check if cost_basis is known (has a source and positive value)
  def cost_basis_known?
    cost_basis.present? && cost_basis.positive? && cost_basis_source.present?
  end

  # Human-readable source label for UI display
  def cost_basis_source_label
    return nil unless cost_basis_source.present?

    I18n.t("holdings.cost_basis_sources.#{cost_basis_source}")
  end

  private
    def amount_in_account_currency
      return amount if currency == account.currency

      Money.new(amount, currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      nil
    end

    def calculate_trend
      return nil unless amount_money
      return nil if avg_cost.nil? # Can't calculate trend without cost basis (0 is valid for airdrops)

      start_amount = qty * avg_cost

      Trend.new \
        current: amount_money,
        previous: start_amount
    end

    # Calculates weighted average cost from buy trades.
    # Returns nil if no trades exist or a cross-currency lot is missing an exchange rate.
    # Uses the same nearest-rate lookback as Money#exchange_to / find_or_fetch_rate so
    # weekend and holiday trade dates agree with calculator-stored cost_basis.
    def calculate_avg_cost
      holding_currency = currency
      lookback_days = ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS

      trades = account.trades
        .with_entry
        .joins(ActiveRecord::Base.sanitize_sql_array([
          "LEFT JOIN LATERAL (
            SELECT exchange_rates.rate
            FROM exchange_rates
            WHERE exchange_rates.from_currency = trades.currency
              AND exchange_rates.to_currency = ?
              AND exchange_rates.date <= entries.date
              AND exchange_rates.date >= (entries.date - ?)
            ORDER BY exchange_rates.date DESC
            LIMIT 1
          ) exchange_rates ON TRUE",
          holding_currency,
          lookback_days
        ]))
        .where(security_id: security.id)
        .where("trades.qty > 0 AND entries.date <= ?", date)

      total_cost, total_qty, missing_fx_count = trades.pick(
        Arel.sql(ActiveRecord::Base.sanitize_sql_array([
          "SUM(trades.price * trades.qty * CASE WHEN trades.currency = ? THEN 1 ELSE exchange_rates.rate END)",
          holding_currency
        ])),
        Arel.sql("SUM(trades.qty)"),
        Arel.sql(ActiveRecord::Base.sanitize_sql_array([
          "COUNT(*) FILTER (WHERE trades.currency <> ? AND exchange_rates.rate IS NULL)",
          holding_currency
        ]))
      )

      return nil if missing_fx_count.to_i > 0
      return nil unless total_qty && total_qty > 0

      Money.new(total_cost / total_qty, holding_currency)
    end
end
