# frozen_string_literal: true

class ProviderConnectionStatus
  PROVIDERS = [
    { key: "plaid", type: "PlaidItem", association: :plaid_items, accounts: :plaid_accounts },
    { key: "simplefin", type: "SimplefinItem", association: :simplefin_items, accounts: :simplefin_accounts },
    { key: "lunchflow", type: "LunchflowItem", association: :lunchflow_items, accounts: :lunchflow_accounts },
    { key: "enable_banking", type: "EnableBankingItem", association: :enable_banking_items, accounts: :enable_banking_accounts },
    { key: "coinbase", type: "CoinbaseItem", association: :coinbase_items, accounts: :coinbase_accounts },
    { key: "binance", type: "BinanceItem", association: :binance_items, accounts: :binance_accounts },
    { key: "kraken", type: "KrakenItem", association: :kraken_items, accounts: :kraken_accounts },
    { key: "coinstats", type: "CoinstatsItem", association: :coinstats_items, accounts: :coinstats_accounts },
    { key: "snaptrade", type: "SnaptradeItem", association: :snaptrade_items, accounts: :snaptrade_accounts, linked_accounts: :linked_accounts },
    { key: "ibkr", type: "IbkrItem", association: :ibkr_items, accounts: :ibkr_accounts },
    { key: "mercury", type: "MercuryItem", association: :mercury_items, accounts: :mercury_accounts },
    { key: "sophtron", type: "SophtronItem", association: :sophtron_items, accounts: :sophtron_accounts },
    { key: "indexa_capital", type: "IndexaCapitalItem", association: :indexa_capital_items, accounts: :indexa_capital_accounts }
  ].freeze

  class << self
    def for_family(family)
      PROVIDERS.flat_map do |provider|
        relation = family.public_send(provider[:association])
        items = relation.includes(association_includes_for(relation, provider)).ordered.to_a
        sync_contexts = sync_contexts_for(provider[:type], items)

        items.map do |item|
          new(provider, item, sync_contexts.fetch(item.id, {})).to_h
        end
      end
    end

    private

      def association_includes_for(relation, provider)
        includes = [ { provider[:accounts] => :account_provider } ]
        includes << provider[:linked_accounts] if provider[:linked_accounts]
        includes << :accounts if relation.klass.reflect_on_association(:accounts)
        includes
      end

      def sync_contexts_for(provider_type, items)
        item_ids = items.map(&:id)
        return {} if item_ids.empty?

        latest_syncs = latest_syncs_for(provider_type, item_ids)
        latest_completed_syncs = latest_syncs_for(provider_type, item_ids, scope: Sync.completed)
        syncing_item_ids = Sync.visible
                              .where(syncable_type: provider_type, syncable_id: item_ids)
                              .distinct
                              .pluck(:syncable_id)

        item_ids.index_with do |item_id|
          {
            latest_sync: latest_syncs[item_id],
            latest_completed_sync: latest_completed_syncs[item_id],
            syncing: syncing_item_ids.include?(item_id)
          }
        end
      end

      def latest_syncs_for(provider_type, item_ids, scope: Sync.all)
        ranked_syncs = scope.where(syncable_type: provider_type, syncable_id: item_ids)
                            .select(
                              "syncs.*, " \
                              "ROW_NUMBER() OVER (PARTITION BY syncable_id ORDER BY created_at DESC, id DESC) AS sync_rank"
                            )

        Sync.from(ranked_syncs, :syncs).where("sync_rank = 1").index_by(&:syncable_id)
      end
  end

  def initialize(provider, item, sync_context = {})
    @provider = provider
    @item = item
    @sync_context = sync_context
  end

  def to_h
    {
      id: item.id,
      provider: provider[:key],
      provider_type: provider[:type],
      name: item_value(:name, provider[:key].humanize),
      status: item_value(:status),
      requires_update: item_boolean(:requires_update?),
      credentials_configured: credentials_configured?,
      scheduled_for_deletion: item_boolean(:scheduled_for_deletion?),
      pending_account_setup: pending_account_setup?,
      institution: institution_payload,
      accounts: accounts_payload,
      sync: sync_payload,
      created_at: item.created_at,
      updated_at: item.updated_at
    }
  end

  private

    attr_reader :provider, :item, :sync_context

    def credentials_configured?
      item_boolean(:credentials_configured?)
    end

    def pending_account_setup?
      item_boolean(:pending_account_setup?)
    end

    def institution_payload
      {
        name: item_value(:institution_display_name, item_value(:name, provider[:key].humanize)),
        domain: item_value(:institution_domain),
        url: item_value(:institution_url)
      }
    end

    def accounts_payload
      @accounts_payload ||= begin
        total = provider_account_count
        linked = linked_account_count

        {
          total_count: total,
          linked_count: linked,
          unlinked_count: [ total - linked, 0 ].max
        }
      end
    end

    def provider_account_count
      records = provider_account_records
      return records.size if records
      return item.total_accounts_count if item.respond_to?(:total_accounts_count)

      0
    end

    def linked_account_count
      records = provider_account_records
      return records.count { |provider_account| linked_provider_account?(provider_account) } if records
      return item.linked_accounts_count if item.respond_to?(:linked_accounts_count)

      if provider[:linked_accounts] && item.respond_to?(provider[:linked_accounts])
        return item.public_send(provider[:linked_accounts]).size
      end

      return item.accounts.size if item.respond_to?(:accounts)

      0
    end

    def provider_account_records
      return unless item.respond_to?(provider[:accounts])

      @provider_account_records ||= item.public_send(provider[:accounts]).to_a
    end

    def linked_provider_account?(provider_account)
      return false unless provider_account.respond_to?(:account_provider)

      association = provider_account.association(:account_provider)
      association.loaded? ? association.target.present? : provider_account.account_provider.present?
    end

    def sync_payload
      {
        syncing: syncing?,
        status_summary: sync_status_summary,
        last_synced_at: latest_completed_sync&.completed_at,
        latest: latest_sync_payload(latest_sync)
      }
    end

    def sync_status_summary
      stats = latest_completed_sync_stats
      counts = accounts_payload
      total = stats.fetch("total_accounts", counts[:total_count]).to_i
      linked = stats.fetch("linked_accounts", counts[:linked_count]).to_i
      unlinked = stats.fetch("unlinked_accounts", [ total - linked, 0 ].max).to_i

      if total.zero?
        "No accounts found"
      elsif unlinked.zero?
        "#{linked} #{'account'.pluralize(linked)} synced"
      else
        "#{linked} synced, #{unlinked} need setup"
      end
    end

    def syncing?
      return sync_context[:syncing] if sync_context.key?(:syncing)

      item_boolean(:syncing?)
    end

    def latest_sync
      sync_context[:latest_sync]
    end

    def latest_completed_sync
      sync_context[:latest_completed_sync]
    end

    def latest_completed_sync_stats
      stats = latest_completed_sync&.sync_stats
      return stats.stringify_keys if stats.is_a?(Hash)
      return {} unless stats.is_a?(String)

      parsed = JSON.parse(stats)
      parsed.is_a?(Hash) ? parsed.stringify_keys : {}
    rescue JSON::ParserError
      {}
    end

    def latest_sync_payload(sync)
      return unless sync

      {
        id: sync.id,
        status: sync.status,
        created_at: sync.created_at,
        syncing_at: sync.syncing_at,
        completed_at: sync.completed_at,
        failed_at: sync.failed_at,
        error: sync_error_payload(sync)
      }
    end

    def sync_error_payload(sync)
      return unless sync.failed? || sync.stale?

      # Provider health treats stale connections as actionable even when the
      # generic sync API suppresses stale-without-error payloads.
      {
        present: true,
        message: sync.stale? ? "Sync became stale before completion" : "Sync failed"
      }
    end

    def item_boolean(method_name)
      item_value(method_name, false) == true
    end

    def item_value(method_name, default = nil)
      return default unless item.respond_to?(method_name)

      item.public_send(method_name)
    end
end
