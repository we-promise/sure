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

    # Refresh the SimpleFin card on Providers/Accounts pages so badges and statuses update without a full reload
    begin
      card_html = ApplicationController.render(
        partial: "simplefin_items/simplefin_item",
        formats: [ :html ],
        locals: { simplefin_item: item }
      )
      target_id = ActionView::RecordIdentifier.dom_id(item)
      Turbo::StreamsChannel.broadcast_replace_to(item.family, target: target_id, html: card_html)

      # Also refresh Manual Accounts so the CTA state and duplicates clear without refresh
      begin
        manual_accounts = item.family.accounts
          .visible_manual
          .order(:name)
        if manual_accounts.any?
          manual_html = ApplicationController.render(
            partial: "accounts/index/manual_accounts",
            formats: [ :html ],
            locals: { accounts: manual_accounts }
          )
          Turbo::StreamsChannel.broadcast_update_to(item.family, target: "manual-accounts", html: manual_html)
        else
          manual_html = ApplicationController.render(inline: '<div id="manual-accounts"></div>')
          Turbo::StreamsChannel.broadcast_replace_to(item.family, target: "manual-accounts", html: manual_html)
        end
      rescue => inner
        Rails.logger.warn("SimpleFin BalancesOnlyJob manual-accounts broadcast failed: #{inner.class} - #{inner.message}")
      end
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob broadcast failed: #{e.class} - #{e.message}")
    end
  end
end
