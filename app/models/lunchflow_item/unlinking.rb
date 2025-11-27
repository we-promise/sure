# frozen_string_literal: true

module LunchflowItem::Unlinking
  # Concern that encapsulates unlinking logic for a Lunchflow item.
  # Mirrors the SimplefinItem::Unlinking behavior.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this Lunchflow item and local accounts.
  # - Detaches any AccountProvider links for each LunchflowAccount
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-account result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    lunchflow_accounts.find_each do |lfa|
      links = AccountProvider.where(provider_type: "LunchflowAccount", provider_id: lfa.id).to_a
      link_ids = links.map(&:id)
      result = {
        lfa_id: lfa.id,
        name: lfa.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          # Detach holdings for any provider links found
          if link_ids.any?
            Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
          end

          # Destroy all provider links
          links.each do |ap|
            ap.destroy!
          end
        end
      rescue => e
        Rails.logger.warn(
          "LunchflowItem Unlinker: failed to fully unlink LFA ##{lfa.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
