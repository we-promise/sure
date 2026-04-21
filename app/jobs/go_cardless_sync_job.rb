class GoCardlessSyncJob < ApplicationJob
  queue_as :default

  def perform(item_id)
    item = GocardlessItem.find(item_id)
    return unless item.bank_connected?

    item.gocardless_accounts.each do |gc_account|
      Provider::GocardlessAdapter.new(gc_account).sync_data
    rescue => e
      Rails.logger.error "Sync failed for GocardlessAccount #{gc_account.id}: #{e.message}"
    end
  end
end