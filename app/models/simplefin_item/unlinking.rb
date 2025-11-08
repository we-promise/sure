# frozen_string_literal: true

module SimplefinItem::Unlinking
  # Concern that encapsulates unlinking logic for a SimpleFin item.
  # Mirrors the previous SimplefinItem::Unlinker service behavior.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this SimpleFin item and local accounts.
  # - Detaches any AccountProvider links for each SimplefinAccount
  # - Nullifies legacy Account.simplefin_account_id backrefs
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-SFA result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    simplefin_accounts.includes(:account).find_each do |sfa|
      links = AccountProvider.where(provider_type: "SimplefinAccount", provider_id: sfa.id).to_a
      link_ids = links.map(&:id)
      result = {
        sfa_id: sfa.id,
        name: sfa.name,
        account_id: sfa.account_id,
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

          # Legacy FK fallback: ensure any legacy link is cleared
          if sfa.account_id.present?
            sfa.update!(account: nil)
          end
        end
      rescue => e
        Rails.logger.warn(
          "Unlinker: failed to fully unlink SFA ##{sfa.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other SFAs
        result[:error] = e.message
      end
    end

    results
  end
end
