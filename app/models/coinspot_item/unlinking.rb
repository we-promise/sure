# frozen_string_literal: true

module CoinspotItem::Unlinking
  extend ActiveSupport::Concern

  # Detaches every CoinSpot account's link to its Sure account, clearing the
  # provider reference off any holdings first so they aren't destroyed along
  # with the link. Returns a per-account result array describing what would
  # be (or was) unlinked; pass dry_run: true to preview without changing
  # anything. A single account's unlink failure is captured on its result
  # and logged rather than aborting the rest.
  def unlink_all!(dry_run: false)
    results = []
    links_by_provider_id = AccountProvider
      .where(provider_type: CoinspotAccount.name, provider_id: coinspot_accounts.select(:id))
      .group_by { |link| link.provider_id.to_s }

    coinspot_accounts.find_each do |provider_account|
      links = links_by_provider_id[provider_account.id.to_s] || []
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
        Rails.logger.warn("CoinspotItem Unlinker: failed to unlink ##{provider_account.id}: #{e.class} - #{e.message}")
        result[:error] = e.message
      end
    end

    results
  end
end
