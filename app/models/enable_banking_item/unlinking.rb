# frozen_string_literal: true

module EnableBankingItem::Unlinking
  # Concern that encapsulates unlinking logic for an Enable Banking item.
  # Mirrors the LunchflowItem::Unlinking behavior.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this Enable Banking item and local accounts.
  # - Detaches any AccountProvider links for each EnableBankingAccount
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-account result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    enable_banking_accounts.find_each do |eba|
      links = AccountProvider.where(provider_type: "EnableBankingAccount", provider_id: eba.id).to_a
      link_ids = links.map(&:id)
      result = {
        eba_id: eba.id,
        name: eba.name,
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
          "EnableBankingItem Unlinker: failed to fully unlink EBA ##{eba.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
