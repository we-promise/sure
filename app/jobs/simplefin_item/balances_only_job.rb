# frozen_string_literal: true

class SimplefinItem::BalancesOnlyJob < ApplicationJob
  queue_as :default

  # Performs a lightweight, balances-only discovery:
  # - import_balances_only
  # - retain last_synced_at so the next full sync still imports history
  # Ordinary failures remain best-effort; ownership denials must escape.
  def perform(simplefin_item_id)
    item = SimplefinItem.select(:id, :family_id).find_by(id: simplefin_item_id)
    return unless item

    Provider::AccountData::LegacyWriterFence.with_item(item, operation: :ingest) do |current|
      import_balances(current)
      Provider::AccountData::LegacyWriterFence.with_item(current, operation: :ingest) do |fresh|
        broadcast_item(fresh.reload)
      end
    end
  end

  private

    def import_balances(item)
      SimplefinItem::Importer
        .new(item)
        .import_balances_only
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged,
        Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => error
      capture_failure(item, error, "SimpleFIN balances-only discovery failed")
    end

    # IMPORTANT: Do NOT update last_synced_at during balances-only discovery.
    # Leaving last_synced_at nil ensures the next full sync uses the
    # chunked-history path to fetch historical transactions.

    def broadcast_item(item)
      card_html = ApplicationController.render(
        partial: "simplefin_items/simplefin_item",
        formats: [ :html ],
        locals: { simplefin_item: item }
      )
      target_id = ActionView::RecordIdentifier.dom_id(item)
      Turbo::StreamsChannel.broadcast_replace_to(item.family, target: target_id, html: card_html)

      # Broadcast a refresh signal instead of rendered HTML. Each user's browser
      # re-fetches via their own authenticated request, so the manual accounts
      # list is correctly scoped to the current user.
      item.family.broadcast_refresh
    rescue Provider::AccountData::LegacyWriterFence::Busy, Provider::AccountData::LegacyWriterFence::OwnershipChanged,
        Provider::AccountData::LegacyWriterFence::InvalidSource
      raise
    rescue StandardError => error
      capture_failure(item, error, "SimpleFIN balances-only refresh broadcast failed")
    end

    def capture_failure(item, error, message)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: message,
        source: self.class.name, provider_key: "simplefin", family: item.family,
        metadata: { item_id: item.id, error_class: error.class.name })
    end
end
