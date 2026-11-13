class DataCacheClearJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    ActiveRecord::Base.transaction do
      ExchangeRate.delete_all
      Security::Price.delete_all
      family.accounts.each do |account|
        account.balances.delete_all
        account.holdings.delete_all
      end

      family.sync_later
      sync_daily_scheduled_items(family)
    end
  end

  private
    # The family sync leaves out connections on their own schedule of a day or
    # longer, but their accounts' balances and holdings were just cleared too.
    # Each such connection is synced so provider holdings are imported again,
    # and each of its accounts is rebuilt on its own, since a connection sync
    # already running is reused and would not see the cleared data.
    def sync_daily_scheduled_items(family)
      items = Family::Syncer.syncable_item_associations.flat_map do |association|
        SyncSchedule.with_own_daily_schedule(family.public_send(association).syncable).to_a
      end
      return if items.empty?

      items.each(&:sync_later)

      keys = items.map { |item| [ item.class.name, item.id ] }.to_set
      family.accounts.each do |account|
        account.sync_later if account_items(account).any? { |item| keys.include?([ item.class.name, item.id ]) }
      end
    end

    def account_items(account)
      [
        *account.providers.filter_map { |adapter| adapter.try(:item) },
        account.plaid_account&.plaid_item,
        account.simplefin_account&.simplefin_item
      ].compact
    end
end
