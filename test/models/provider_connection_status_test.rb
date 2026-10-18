# frozen_string_literal: true

require "test_helper"

class ProviderConnectionStatusTest < ActiveSupport::TestCase
  test "CA Auto Bank status requests reconnect after expiry without exposing bank credentials" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:key] == "ca_auto_bank" }
    item = CaAutoBankItem.new(family: families(:dylan_family), owner: users(:family_admin),
      authentication_token: "private-bank-token", account_identity: "private-bank-identity",
      request_session_id: "private-bank-session", pending_login_state: "private-bank-approval",
      session_expires_at: 1.hour.from_now, status: :connected)

    result = ProviderConnectionStatus.new(provider, item).to_h
    assert_equal "CA Auto Bank", result[:name]
    assert result[:credentials_configured]
    refute result[:requires_update]
    %w[private-bank-token private-bank-identity private-bank-session private-bank-approval].each do |secret|
      refute_includes result.to_json, secret
    end
    travel 61.minutes do
      expired = ProviderConnectionStatus.new(provider, item).to_h
      refute expired[:credentials_configured]
      assert expired[:requires_update]
    end
  end

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

  test "Fineco status reports a configured session without exposing credential fields" do
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :fineco_items }
    item = FinecoItem.new(
      family: families(:dylan_family),
      owner: users(:family_admin),
      gsessionid: "synthetic-session",
      account_index: "2",
      dossier_index: "11",
      bank_account_number: "SYNTHETIC-ACCOUNT",
      dossier_identity: Digest::SHA256.hexdigest("synthetic-dossier"),
      captured_at: Time.current
    )

    status = ProviderConnectionStatus.new(provider, item).to_h

    assert_equal "fineco", status[:provider]
    assert_equal true, status[:credentials_configured]
    refute_includes status.keys, :gsessionid
    refute_includes status.keys, :account_index
    refute_includes status.keys, :dossier_index
    refute_includes status.keys, :bank_account_number
    refute_includes status.keys, :dossier_identity
  end

  test "Directa status reports its session without exposing credential fields" do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :directa_items }
    item = DirectaItem.new(
      family: families(:dylan_family),
      owner: users(:family_admin),
      broker_account: "00123",
      account_identity: "00123",
      multi_token: "synthetic-multi-token",
      mono_token: "synthetic-mono-token",
      pending_login_state: "synthetic-pending-state",
      connection_generation: 1,
      status: :connected
    )

    status = ProviderConnectionStatus.new(provider, item).to_h

    assert_equal "directa", status[:provider]
    assert_equal "DirectaItem", status[:provider_type]
    assert_equal true, status[:credentials_configured]
    assert_equal 0, status.dig(:accounts, :total_count)
    %i[broker_account account_identity multi_token mono_token pending_login_state].each do |field|
      refute_includes status.keys, field
    end
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

  test "simplefin provider status does not require setup token after partial account sync" do
    family = families(:dylan_family)
    item = SimplefinItem.create!(
      family: family,
      name: "SimpleFIN",
      access_url: "https://example.com/access",
      status: :requires_update,
      pending_account_setup: true
    )
    completed_sync = item.syncs.create!(
      status: "completed",
      created_at: Time.current,
      completed_at: Time.current,
      sync_stats: {
        total_accounts: 18,
        linked_accounts: 17,
        unlinked_accounts: 1,
        error_buckets: { auth: 1 }
      }
    )
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :simplefin_items }

    item.expects(:syncs).never

    status = ProviderConnectionStatus.new(
      provider,
      item,
      latest_sync: completed_sync,
      latest_completed_sync: completed_sync,
      syncing: false
    ).to_h

    assert_equal "good", status[:status]
    assert_equal false, status[:requires_update]
    assert_equal true, status[:pending_account_setup]
    assert_equal "17 synced, 1 need setup", status.dig(:sync, :status_summary)
  end

  test "trade republic provider status requires an update once its session ended" do
    item = trade_republic_items(:configured_item)
    item.update_columns(status: "good", session_expires_at: 1.minute.ago)
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :trade_republic_items }

    status = ProviderConnectionStatus.new(provider, item, syncing: false).to_h

    assert_equal "requires_update", status[:status]
    assert_equal true, status[:requires_update]

    item.update_columns(session_expires_at: 1.hour.from_now)
    status = ProviderConnectionStatus.new(provider, item.reload, syncing: false).to_h

    assert_equal "good", status[:status]
    assert_equal false, status[:requires_update]
  end
end
