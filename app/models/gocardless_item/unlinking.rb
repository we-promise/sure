module GocardlessItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    gocardless_accounts.find_each do |gc_account|
      links    = AccountProvider.where(provider_type: GocardlessAccount.polymorphic_name, provider_id: gc_account.id).to_a
      link_ids = links.map(&:id)

      result = {
        gc_account_id:     gc_account.id,
        name:              gc_account.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
          links.each(&:destroy!)
        end
      rescue => e
        Rails.logger.warn "GocardlessItem::Unlinking - Failed to unlink GocardlessAccount ##{gc_account.id}: #{e.message}"
        result[:error] = e.message
      end
    end

    results
  end
end