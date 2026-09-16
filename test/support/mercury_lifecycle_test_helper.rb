require_relative "provider_ingestion_test_helper"

module MercuryLifecycleTestHelper
  include ProviderIngestionTestHelper

  def with_mercury_context
    with_provider_encryption do
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        family = Family.create!(name: "Mercury lifecycle")
        actor = family.users.create!(email: "mercury-lifecycle-#{SecureRandom.uuid}@example.com", password: "mercury-test-password", role: "admin")
        item = family.mercury_items.create!(name: "Mercury", token: "original-token")
        yield item, actor
      ensure
        if family
          ids = family.accounts.pluck(:id)
          Account::SourcePolicy.where(family_id: family.id).delete_all
          Holding.where(account_id: ids).destroy_all
          AccountProvider.where(account_id: ids).delete_all
          family.accounts.each(&:destroy!)
          ProviderMigrationMapping.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.provider_connections.each do |connection|
            connection.syncs.destroy_all
            connection.destroy!
          end
          item_ids = family.mercury_items.pluck(:id)
          Sync.where(syncable_type: "MercuryItem", syncable_id: item_ids).destroy_all
          MercuryAccount.where(mercury_item_id: item_ids).delete_all
          MercuryItem.where(id: item_ids).delete_all
          Session.where(user_id: family.users.select(:id)).delete_all
          family.users.delete_all
          family.destroy!
        end
      end
    end
  end

  def mercury_rows
    [ { id: "checking-1", nickname: "Business checking", name: "Checking", currentBalance: 125, type: "checking", status: "active" } ]
  end

  def mercury_provider(&read)
    provider = Object.new
    rows = mercury_rows
    test = self
    provider.define_singleton_method(:get_accounts) do
      test.assert_equal 0, ApplicationRecord.connection.open_transactions
      read&.call
      { accounts: rows }
    end
    Provider::Mercury.stubs(:new).returns(provider)
    provider
  end

  def mercury_command(item, actor)
    MercuryItem::Lifecycle.new(item: item, actor: actor)
  end

  def mercury_selection(result, flow:, account_id: nil)
    MercuryItem::Selection.from_token(result.fetch(:selection_token), flow: flow, account_id: account_id)
  end

  def mercury_financial(item, actor, name: "Manual")
    item.family.accounts.create!(owner: actor, name: name, currency: "USD", balance: 9, accountable: Depository.new)
  end
end
