# frozen_string_literal: true

# Provides unlinking functionality for CoinStats items.
# Allows disconnecting provider accounts while preserving account data.
module CoinstatsItem::Unlinking
  extend ActiveSupport::Concern

  # Removes all connections between this item and local accounts.
  # Detaches AccountProvider links and nullifies associated Holdings.
  # @param dry_run [Boolean] If true, returns results without making changes
  # @return [Array<Hash>] Results per account with :provider_account_id, :name, :provider_link_ids
  def unlink_all!(dry_run: false)
    results = []

    coinstats_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: CoinstatsAccount.name, provider_id: provider_account.id).to_a
      link_ids = links.map(&:id)
      result = {
        provider_account_id: provider_account.id,
        name: provider_account.name,
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
      rescue StandardError => e
        Rails.logger.warn(
          "CoinstatsItem Unlinker: failed to fully unlink provider account ##{provider_account.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
