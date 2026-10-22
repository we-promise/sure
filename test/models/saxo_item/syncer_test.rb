require "test_helper"

class SaxoItem::SyncerTest < ActiveSupport::TestCase
  test "history validation details reach the sync diagnostic" do
    item = families(:dylan_family).saxo_items.create!
    provider_account = item.saxo_accounts.create!(account_id: "123", name: "Saxo", currency: "EUR")
    provider_account.link!
    diagnostic = { account_provider_id: provider_account.account_provider.id, stage: "history", location: "transaction", asset_type: "Fund", uic_present: true, currency_valid: false }
    error = Provider::Saxo::Error.new("Saxo instrument type is not supported", diagnostic: diagnostic)
    SaxoItem::Importer.any_instance.stubs(:import).raises(error)
    syncer = SaxoItem::Syncer.new(item)
    syncer.stubs(:collect_health_stats)

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises(Provider::Saxo::Error) { syncer.perform_sync(Object.new) }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal provider_account.account_provider, entry.account_provider
    assert_equal item.family, entry.family
    assert_equal "saxo", entry.provider_key
    assert_equal diagnostic.stringify_keys.merge("saxo_item_id" => item.id), entry.metadata
  end
end
