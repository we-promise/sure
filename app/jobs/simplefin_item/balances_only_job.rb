# frozen_string_literal: true

class SimplefinItem::BalancesOnlyJob < ApplicationJob
  queue_as :default

  # Performs a lightweight, balances-only discovery:
  # - import_balances_only
  # - update last_synced_at (when column exists)
  # Any exceptions are logged and safely swallowed to avoid breaking user flow.
  def perform(simplefin_item_id)
    item = SimplefinItem.find_by(id: simplefin_item_id)
    return unless item

    begin
      SimplefinItem::Importer
        .new(item, simplefin_provider: item.simplefin_provider)
        .import_balances_only
    rescue Provider::Simplefin::SimplefinError, ArgumentError, StandardError => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob import failed: #{e.class} - #{e.message}")
    end

    # IMPORTANT: Do NOT update last_synced_at during balances-only discovery.
    # Leaving last_synced_at nil ensures the next full sync uses the
    # chunked-history path to fetch historical transactions.

    # Refresh Providers/Accounts pages so badges and statuses update without a manual reload
    begin
      # Broadcast a refresh signal instead of rendered HTML. Each user's browser
      # re-fetches via their own authenticated request, so the manual accounts
      # list and the SimpleFIN card are scoped to the current user (#3630).
      item.family.broadcast_refresh
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob broadcast failed: #{e.class} - #{e.message}")
    end
  end
end
