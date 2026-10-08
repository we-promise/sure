# frozen_string_literal: true

# Trade Republic quotes bonds in percent of par (84.04 = 84.04%) while the
# position size is the nominal amount in currency units. Syncs before the
# percent-of-par fix stored that quote as the per-unit price, so every bond
# holding snapshot they wrote is valued 100x too high. A sync only rewrites
# today's snapshot, which leaves the bond's history inflated for good.
#
# Every snapshot that exists when this runs was written by the old code, so
# the only question is which rows are bonds. Bonds and interest products
# share the `interest_products` category, and only bonds were ever quoted in
# percent. A percent quote sits around 100x the per-unit average buy-in, a
# per-unit price around 1x, so a price at least 10x the buy-in tells them
# apart. That check also leaves an already corrected row alone, so running
# this twice is harmless.
#
# Bonds still held are found through the stored portfolio payload. Sold bonds
# are no longer in it, but the old code put every bond on the shared BOND
# listing on Hamburg (Trade Republic's LSX), so those rows are found by that
# security instead.
#
# The stored payload keeps the percent quote as well, and a sync that gets
# no quote reuses it, which would write a 100x snapshot again. Its bond
# prices are rescaled under the same check.
#
# Balances and the account's current value were computed from the inflated
# prices too; the item sync scheduled at the end refreshes them.
class RescaleTradeRepublicBondHoldingPrices < ActiveRecord::Migration[8.1]
  PERCENT_QUOTE_RATIO = 10
  SHARED_BOND_TICKER = "BOND"
  SHARED_BOND_MIC = "XHAM"

  def up
    bond_security_ids = Security.where(ticker: SHARED_BOND_TICKER, exchange_operating_mic: SHARED_BOND_MIC).pluck(:id)
    item_ids = []

    TradeRepublicAccount.where(kind: "portfolio").includes(:account_provider).find_each do |trade_republic_account|
      account = trade_republic_account.current_account
      provider_id = trade_republic_account.account_provider&.id
      next if account.nil? || provider_id.nil?

      snapshots = account.holdings
        .where(account_provider_id: provider_id)
        .where("external_id LIKE ?", "#{snapshot_prefix(trade_republic_account)}%")
      bond_positions = Array(trade_republic_account.raw_positions_payload).map { |position| position.to_h.with_indifferent_access }
        .select { |position| position[:isin].present? && position[:category].to_s == "interest_products" }

      rescaled = bond_positions.sum do |position|
        rescale_percent_quotes(
          snapshots.where("external_id LIKE ?", "#{snapshot_prefix(trade_republic_account, position[:isin])}%"),
          fallback_cost: parse_decimal(position[:average_cost])
        )
      end
      rescaled += rescale_percent_quotes(snapshots.where(security_id: bond_security_ids)) if bond_security_ids.any?
      payload_rescaled = rescale_payload_prices(trade_republic_account)
      next if rescaled.zero? && !payload_rescaled

      say "Rescaled #{rescaled} Trade Republic bond holdings on account #{account.id}"
      item_ids << trade_republic_account.trade_republic_item_id
    end

    schedule_syncs(item_ids.uniq)
  end

  # The old prices were wrong; restoring them would bring back the 100x error.
  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

    def snapshot_prefix(trade_republic_account, isin = nil)
      ActiveRecord::Base.sanitize_sql_like(
        "trade_republic_position_#{trade_republic_account.trade_republic_account_id}_#{isin.present? ? "#{isin}_" : ""}"
      )
    end

    def rescale_percent_quotes(holdings, fallback_cost: nil)
      holdings
        .where("price >= NULLIF(COALESCE(cost_basis, ?), 0) * ?", fallback_cost, PERCENT_QUOTE_RATIO)
        .update_all("price = price / 100, amount = amount / 100, updated_at = CURRENT_TIMESTAMP")
    end

    def rescale_payload_prices(trade_republic_account)
      changed = false
      payload = Array(trade_republic_account.raw_positions_payload).map do |position|
        next position unless position.is_a?(Hash) && position["category"].to_s == "interest_products"

        price = parse_decimal(position["price"])
        average_cost = parse_decimal(position["average_cost"])
        next position unless price && average_cost&.positive? && price >= average_cost * PERCENT_QUOTE_RATIO

        changed = true
        position.merge("price" => (price / 100).to_s("F"))
      end
      trade_republic_account.update_column(:raw_positions_payload, payload) if changed
      changed
    end

    def schedule_syncs(item_ids)
      TradeRepublicItem.syncable.where(id: item_ids).find_each do |item|
        item.sync_later
      rescue => e
        say "Could not schedule a sync for Trade Republic item #{item.id} (#{e.message}); it refreshes on its next sync"
      end
    end

    def parse_decimal(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      decimal if decimal.finite?
    rescue ArgumentError
      nil
    end
end
