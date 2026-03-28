# frozen_string_literal: true

module KrakenItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    kraken_accounts.find_each do |provider_account|
      links = AccountProvider.where(provider_type: KrakenAccount.name, provider_id: provider_account.id).to_a
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
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
          links.each(&:destroy!)
        end
      rescue StandardError => e
        Rails.logger.warn(
          "KrakenItem Unlinker: failed to fully unlink provider account ##{provider_account.id}: #{e.class} - #{e.message}"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
