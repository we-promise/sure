# frozen_string_literal: true

module CoinbaseItem::Unlinking
  # Concern that encapsulates unlinking logic for a Coinbase item.
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this Coinbase item and local accounts.
  # - Detaches any AccountProvider links for each CoinbaseAccount
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-account result payload for observability
  def unlink_all!(dry_run: false)
    results = []

    coinbase_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: CoinbaseAccount.name, provider_id: provider_account.id).to_a
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
          "CoinbaseItem Unlinker: failed to fully unlink provider account ##{provider_account.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        # Record error for observability; continue with other accounts
        result[:error] = e.message
      end
    end

    results
  end
end
