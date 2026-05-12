# frozen_string_literal: true

require "test_helper"

class ProviderConnectionStatusTest < ActiveSupport::TestCase
  test "provider registry covers syncable family provider item associations" do
    expected_registry = Family.reflect_on_all_associations(:has_many).filter_map do |association|
      next unless association.name.to_s.end_with?("_items")
      next unless association.klass.included_modules.include?(Syncable)

      { association: association.name, type: association.klass.name }
    end

    registered_registry = ProviderConnectionStatus::PROVIDERS.map do |provider|
      { association: provider[:association], type: provider[:type] }
    end

    assert_equal expected_registry.sort_by { |entry| entry[:association].to_s },
                 registered_registry.sort_by { |entry| entry[:association].to_s }
  end

  test "status summary is computed without calling provider item summary" do
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :mercury_items }
    item = mercury_items(:one)
    completed_sync = item.syncs.create!(
      status: "completed",
      created_at: 1.hour.ago,
      completed_at: 1.hour.ago,
      sync_stats: {
        total_accounts: 2,
        linked_accounts: 1,
        unlinked_accounts: 1
      }
    )
    failed_sync = item.syncs.create!(
      status: "failed",
      created_at: Time.current,
      failed_at: Time.current,
      sync_stats: {
        total_accounts: 9,
        linked_accounts: 9,
        unlinked_accounts: 0
      }
    )

    item.expects(:sync_status_summary).never

    status = ProviderConnectionStatus.new(
      provider,
      item,
      latest_sync: failed_sync,
      latest_completed_sync: completed_sync,
      syncing: false
    ).to_h

    assert_equal "1 synced, 1 need setup", status.dig(:sync, :status_summary)
    assert_equal failed_sync.id, status.dig(:sync, :latest, :id)
  end

  test "account counts use provider account links instead of linked account fallback" do
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :mercury_items }
    item = mercury_items(:one)
    linked_provider_account = item.mercury_accounts.create!(
      account_id: "merc_acc_savings_2",
      name: "Mercury Savings",
      currency: "USD"
    )
    AccountProvider.create!(
      account: accounts(:other_asset),
      provider: linked_provider_account
    )

    item.association(:mercury_accounts).reset

    status = ProviderConnectionStatus.new(provider, item, syncing: false).to_h

    assert_equal 2, status.dig(:accounts, :total_count)
    assert_equal 1, status.dig(:accounts, :linked_count)
    assert_equal 1, status.dig(:accounts, :unlinked_count)
  end

  test "kraken provider status is included without credential fields" do
    statuses = ProviderConnectionStatus.for_family(families(:dylan_family))
    kraken_status = statuses.find { |status| status[:provider] == "kraken" }

    assert kraken_status
    assert_equal "KrakenItem", kraken_status[:provider_type]
    refute_includes kraken_status.keys, :api_key
    refute_includes kraken_status.keys, :api_secret
    assert_equal true, kraken_status[:credentials_configured]
  end
end
