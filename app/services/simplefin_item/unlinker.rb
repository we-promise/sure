# frozen_string_literal: true

class SimplefinItem::Unlinker
  attr_reader :item, :dry_run

  def initialize(item, dry_run: false)
    @item = item
    @dry_run = dry_run
  end

  # Idempotently remove all connections between this SimpleFin item and local accounts.
  # - Detaches any AccountProvider links for each SimplefinAccount
  # - Nullifies legacy Account.simplefin_account_id backrefs
  # - Detaches Holdings that point at the AccountProvider links
  # Returns a per-SFA result payload for observability
  def unlink_all!
    results = []

    ActiveRecord::Base.transaction do
      item.simplefin_accounts.includes(:account).find_each do |sfa|
        links = AccountProvider.where(provider_type: "SimplefinAccount", provider_id: sfa.id).to_a
        link_ids = links.map(&:id)
        results << {
          sfa_id: sfa.id,
          name: sfa.name,
          account_id: sfa.account_id,
          provider_link_ids: link_ids
        }

        next if dry_run

        # Detach holdings for any provider links found
        if link_ids.any?
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
        end

        # Destroy all provider links
        links.each do |ap|
          begin
            ap.destroy!
          rescue => e
            Rails.logger.warn("Unlinker: failed to destroy AccountProvider ##{ap.id} for SFA ##{sfa.id}: #{e.class} - #{e.message}")
          end
        end

        # Legacy FK fallback: ensure any legacy link is cleared
        if sfa.account_id.present? || sfa.account.present?
          begin
            sfa.update!(account: nil)
          rescue => e
            Rails.logger.warn("Unlinker: failed to clear legacy account for SFA ##{sfa.id}: #{e.class} - #{e.message}")
          end
        end
      end
    end

    results
  end
end
