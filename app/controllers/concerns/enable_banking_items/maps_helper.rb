# frozen_string_literal: true

module EnableBankingItems
  module MapsHelper
    extend ActiveSupport::Concern

    # Build per-item maps consumed by the enable_banking_item partial.
    # Accepts a single EnableBankingItem or a collection.
    def build_enable_banking_maps_for(items)
      items = Array(items).compact
      return if items.empty?

      @enable_banking_sync_stats_map ||= {}
      @enable_banking_has_unlinked_map ||= {}
      @enable_banking_unlinked_count_map ||= {}
      @enable_banking_duplicate_only_map ||= {}
      @enable_banking_show_relink_map ||= {}
      @enable_banking_latest_sync_error_map ||= {}

      # Batch-check if ANY family has manual accounts (same result for all items from same family)
      family_ids = items.map { |i| i.family_id }.uniq
      families_with_manuals = Account
        .visible_manual
        .where(family_id: family_ids)
        .distinct
        .pluck(:family_id)
        .to_set

      # Batch-fetch unlinked counts for all items in one query
      unlinked_counts = EnableBankingAccount
        .where(enable_banking_item_id: items.map(&:id))
        .left_joins(:account, :account_provider)
        .where(accounts: { id: nil }, account_providers: { id: nil })
        .group(:enable_banking_item_id)
        .count

      items.each do |item|
        # Latest sync stats (avoid N+1; rely on includes(:syncs) where appropriate)
        latest_sync = if item.syncs.loaded?
          item.syncs.max_by(&:created_at)
        else
          item.syncs.ordered.first
        end
        stats = (latest_sync&.sync_stats || {})
        @enable_banking_sync_stats_map[item.id] = stats
        @enable_banking_latest_sync_error_map[item.id] = latest_sync&.error

        # Whether the family has any manual accounts available to link (from batch query)
        @enable_banking_has_unlinked_map[item.id] = families_with_manuals.include?(item.family_id)

        # Count from batch query (defaults to 0 if not found)
        @enable_banking_unlinked_count_map[item.id] = unlinked_counts[item.id] || 0

        # Whether all reported errors for this item are duplicate-account warnings
        @enable_banking_duplicate_only_map[item.id] = compute_duplicate_only_flag(stats)

        # Compute CTA visibility: show relink only when there are zero unlinked SFAs,
        # there exist manual accounts to link, and the item has at least one SFA
        begin
          unlinked_count = @enable_banking_unlinked_count_map[item.id] || 0
          manuals_exist = @enable_banking_has_unlinked_map[item.id]
          sfa_any = if item.enable_banking_accounts.loaded?
            item.enable_banking_accounts.any?
          else
            item.enable_banking_accounts.exists?
          end
          @enable_banking_show_relink_map[item.id] = (unlinked_count.to_i == 0 && manuals_exist && sfa_any)
        rescue StandardError => e
          Rails.logger.warn("Enable Banking card: CTA computation failed for item #{item.id}: #{e.class} - #{e.message}")
          @enable_banking_show_relink_map[item.id] = false
        end
      end
    end

    private
      def compute_duplicate_only_flag(stats)
        errs = Array(stats && stats["errors"]).map do |e|
          if e.is_a?(Hash)
            e["message"] || e[:message]
          else
            e.to_s
          end
        end
        errs.present? && errs.all? { |m| m.to_s.downcase.include?("duplicate upstream account detected") }
      rescue
        false
      end
  end
end
