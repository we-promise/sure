# frozen_string_literal: true

module SimplefinItems
  module MapsHelper
    extend ActiveSupport::Concern

    # Build per-item maps consumed by the simplefin_item partial.
    # Accepts a single SimplefinItem or a collection.
    def build_simplefin_maps_for(items)
      items = Array(items).compact

      @simplefin_sync_stats_map ||= {}
      @simplefin_has_unlinked_map ||= {}
      @simplefin_unlinked_count_map ||= {}
      @simplefin_duplicate_only_map ||= {}
      @simplefin_show_relink_map ||= {}

      items.each do |item|
        # Latest sync stats (avoid N+1; rely on includes(:syncs) where appropriate)
        latest_sync = if item.syncs.loaded?
          item.syncs.max_by(&:created_at)
        else
          item.syncs.ordered.first
        end
        stats = (latest_sync&.sync_stats || {})
        @simplefin_sync_stats_map[item.id] = stats

        # Whether the family has any manual accounts available to link
        @simplefin_has_unlinked_map[item.id] = item.family.accounts
          .left_joins(:account_providers)
          .where(account_providers: { id: nil })
          .exists?

        # Count of SimpleFin accounts for this item that have neither legacy account nor AccountProvider
        count = item.simplefin_accounts
          .left_joins(:account, :account_provider)
          .where(accounts: { id: nil }, account_providers: { id: nil })
          .count
        @simplefin_unlinked_count_map[item.id] = count

        # Whether all reported errors for this item are duplicate-account warnings
        @simplefin_duplicate_only_map[item.id] = compute_duplicate_only_flag(stats)

        # Compute CTA visibility: show relink only when there are zero unlinked SFAs,
        # there exist manual accounts to link, and the item has at least one SFA
        begin
          unlinked_count = @simplefin_unlinked_count_map[item.id] || 0
          manuals_exist = @simplefin_has_unlinked_map[item.id]
          sfa_any = if item.simplefin_accounts.loaded?
            item.simplefin_accounts.any?
          else
            item.simplefin_accounts.exists?
          end
          @simplefin_show_relink_map[item.id] = (unlinked_count.to_i == 0 && manuals_exist && sfa_any)
        rescue => e
          Rails.logger.warn("SimpleFin card: CTA computation failed for item #{item.id}: #{e.class} - #{e.message}")
          @simplefin_show_relink_map[item.id] = false
        end
      end

      # Ensure maps are hashes even when items empty
      @simplefin_sync_stats_map ||= {}
      @simplefin_has_unlinked_map ||= {}
      @simplefin_unlinked_count_map ||= {}
      @simplefin_duplicate_only_map ||= {}
      @simplefin_show_relink_map ||= {}
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
