# frozen_string_literal: true

class SimplefinItem::BalancesOnlyJob < ApplicationJob
  queue_as :default

  # Performs a lightweight, balances-only discovery:
  # - import_balances_only
  # - dedup_simplefin_accounts!
  # - merge_duplicate_provider_accounts! (best-effort)
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

    # Best-effort cleanup and freshness update
    begin
      item.dedup_simplefin_accounts!
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob dedup failed: #{e.class} - #{e.message}")
    end

    begin
      item.merge_duplicate_provider_accounts!
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob merge duplicate accounts failed: #{e.class} - #{e.message}")
    end

    begin
      item.update!(last_synced_at: Time.current) if item.has_attribute?(:last_synced_at)
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob last_synced_at update failed: #{e.class} - #{e.message}")
    end

    # Notify any open modal to refresh its contents with up-to-date relink options
    begin
      url = Rails.application.routes.url_helpers.relink_simplefin_item_path(item)
      html = ApplicationController.render(
        inline: "<turbo-frame id='modal' src='#{ERB::Util.html_escape(url)}'></turbo-frame>",
        formats: [ :html ]
      )
      Turbo::StreamsChannel.broadcast_replace_to(item.family, target: "modal", html: html)
    rescue => e
      Rails.logger.warn("SimpleFin BalancesOnlyJob broadcast failed: #{e.class} - #{e.message}")
    end
  end
end
