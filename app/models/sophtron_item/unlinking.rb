# frozen_string_literal: true

module SophtronItem::Unlinking
  # Concern that encapsulates unlinking logic for a Sophtron item.
  # Mirrors the SimplefinItem::Unlinking behavior.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this Sophtron item and local accounts.
  # - Detaches any AccountProvider links for each SophtronAccount
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-account result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    sophtron_accounts.find_each do |sfa|
      links = AccountProvider.where(provider_type: "SophtronAccount", provider_id: sfa.id).to_a
      link_ids = links.map(&:id)
      result = {
        sfa_id: sfa.id,
        name: sfa.name,
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
          "SophtronItem Unlinker: failed to fully unlink SophtronAccount ##{sfa.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
