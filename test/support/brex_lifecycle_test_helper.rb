require_relative "provider_ingestion_test_helper"

module BrexLifecycleTestHelper
  include ProviderIngestionTestHelper

  def with_brex_context
    with_provider_encryption do
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        family = Family.create!(name: "Brex lifecycle")
        actor = family.users.create!(email: "brex-lifecycle-#{SecureRandom.uuid}@example.com", password: "brex-test-password", role: "admin")
        item = family.brex_items.create!(name: "Brex", token: "original-token")
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
          item_ids = family.brex_items.pluck(:id)
          Sync.where(syncable_type: "BrexItem", syncable_id: item_ids).destroy_all
          BrexAccount.where(brex_item_id: item_ids).delete_all
          BrexItem.where(id: item_ids).delete_all
          Session.where(user_id: family.users.select(:id)).delete_all
          family.users.delete_all
          family.destroy!
        end
      end
    end
  end

  def brex_rows
    [ { id: "checking-1", name: "Business checking", account_kind: "cash", current_balance: { amount: 12_500, currency: "USD" }, status: "active" } ]
  end

  def brex_provider(&read)
    provider = Object.new
    rows = brex_rows
    test = self
    provider.define_singleton_method(:get_accounts) do
      test.assert_equal 0, ApplicationRecord.connection.open_transactions
      read&.call
      { accounts: rows }
    end
    Provider::Brex.stubs(:new).returns(provider)
    provider
  end

  def brex_command(item, actor)
    BrexItem::Lifecycle.new(item: item, actor: actor)
  end

  def brex_selection(result, flow:, account_id: nil)
    BrexItem::Selection.from_token(result.fetch(:selection_token), flow: flow, account_id: account_id)
  end

  def brex_financial(item, actor, name: "Manual")
    item.family.accounts.create!(owner: actor, name: name, currency: "USD", balance: 9, accountable: Depository.new)
  end
end
