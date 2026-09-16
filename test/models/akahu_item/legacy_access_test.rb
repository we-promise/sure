require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuItem::LegacyAccessTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Access = AkahuItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    SyncJob.stubs(:perform_later)
    Account.any_instance.stubs(:sync_later)
  end

  test "quiesced and native owners reject all direct admission paths before mutation" do
    with_source do |item, source, account|
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "akahu", legacy_type: "AkahuItem", legacy_id: item.id)
      begin
        %w[quiescing active retired rollback_pending].each do |state|
          control.update!(state: state)
          assert_raises(Fence::OwnershipChanged) { Access.with_item(item) { flunk "Admitted old item" } }
          assert_raises(Fence::OwnershipChanged) { Access.with_account(source) { flunk "Admitted old account" } }
          assert_raises(Fence::OwnershipChanged) { Access.with_snapshot(item) { flunk "Admitted old snapshot" } }
          assert_raises(Fence::OwnershipChanged) { Access.with_source_snapshot(source) { flunk "Admitted old cache" } }
          assert_raises(Fence::OwnershipChanged) { Access.with_publication(source, expected_account: account) { flunk "Admitted old posting" } }
        end
      ensure
        control.delete
      end
      assert_equal BigDecimal("10"), account.reload.balance
      assert_nil source.reload.raw_transactions_payload
    end
  end

  test "both credentials bind a response to its original transport configuration" do
    %w[app_token user_token].each do |field|
      with_source do |item, source, _account|
        original = Access.transport_context(item)
        original_source = Access.source_context(source)
        item.update!(field => "replacement-token")

        assert_raises(Fence::OwnershipChanged) do
          Access.with_snapshot(item, expected_context: original) { flunk "Accepted stale item response" }
        end
        assert_raises(Fence::OwnershipChanged) do
          Access.with_source_snapshot(source, expected_context: original_source, expected_item_context: original) do
            flunk "Accepted stale account response"
          end
        end
        assert_nil source.reload.raw_payload
      end
    end
  end

  test "relink and stale cache cannot redirect publication to a new financial context" do
    %i[link cache currency].each do |change|
      with_source do |item, source, account|
        stale_source = AkahuAccount.find(source.id)
        Access.source_context(stale_source)
        other = item.family.accounts.create!(name: "Other target", balance: 0, currency: "NZD", accountable: Depository.new)
        begin
          case change
          when :link then source.account_provider.update!(account: other)
          when :cache then source.update!(raw_transactions_payload: [ { "_id" => "new-cache" } ])
          when :currency then Account.where(id: account.id).update_all(currency: "USD")
          end
          assert_raises(Fence::OwnershipChanged) do
            Access.with_publication(stale_source, expected_account: account, resource: "transactions") { flunk "Published stale selection" }
          end
          assert_empty other.entries
          assert_empty account.entries
        ensure
          source.account_provider.update!(account: account)
          other.destroy!
        end
      end
    end
  end

  test "publication pins fresh associations and rolls back the whole yielded financial unit" do
    with_source do |_item, source, account|
      source.account
      before = account.reload.attributes
      assert_raises(RuntimeError) do
        Access.with_publication(source, expected_account: account, resource: "balances") do |fresh, financial|
          assert_same financial, fresh.current_account
          assert_equal source.account_provider.id, fresh.account_provider.id
          assert ApplicationRecord.connection.open_transactions.positive?
          financial.update!(balance: 999)
          raise "Abort publication"
        end
      end
      assert_equal before, account.reload.attributes
    end
  end

  test "inactive selection prevents implicit source promotion while cache snapshots remain writable" do
    with_source do |_item, source, account|
      policy = Account::SourcePolicy.select!(account: account, account_provider: source.account_provider, resource: "transactions")
      policy.update!(active: false)
      assert_raises(Fence::OwnershipChanged) do
        Access.with_publication(source, expected_account: account, resource: "transactions") { flunk "Promoted deselected source" }
      end
      Access.with_source_snapshot(source) { |fresh| fresh.update!(raw_transactions_payload: []) }
      assert_equal [], source.reload.raw_transactions_payload
      assert_empty account.entries
    end
  end

  test "another provider authority refuses financial posting without blocking observations" do
    with_source do |item, source, account|
      other_item = UpItem.create!(family: item.family, name: "Other feed", access_token: "other-test-token")
      other_source = other_item.up_accounts.create!(account_id: "other-remote", name: "Other feed", currency: "NZD")
      other_link = AccountProvider.create!(account: account, provider: other_source)
      begin
        Account::SourcePolicy.select!(account: account, account_provider: other_link, resource: "transactions")
        assert_raises(Fence::OwnershipChanged) do
          Access.with_publication(source, expected_account: account, resource: "transactions") { flunk "Posted through secondary source" }
        end
        Access.with_source_snapshot(source) { |fresh| fresh.update!(raw_transactions_payload: []) }
        assert_equal [], source.reload.raw_transactions_payload
        assert_empty account.entries
      ensure
        Account::SourcePolicy.where(account_id: account.id).delete_all
        other_link.delete
        other_source.delete
        other_item.delete
      end
    end
  end

  test "direct transport refuses any surrounding database transaction" do
    ApplicationRecord.transaction do
      assert_raises(Fence::InvalidSource) { Access.assert_transport! }
    end
    assert_nil Access.assert_transport!
  end

  test "source removal after permit admission remains an ownership denial" do
    with_source do |item, source, _account|
      original = Fence.method(:with_item)
      remove_after_admission = lambda do |selected, operation: :ingest, &work|
        original.call(selected, operation: operation) do |current|
          source.delete
          item.delete
          work.call(current)
        end
      end
      Fence.stub(:with_item, remove_after_admission) do
        assert_raises(Fence::OwnershipChanged) { Access.with_item(item) { flunk "Published after owner removal" } }
      end
    end
  end

  private
    def with_source
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = AkahuItem.create!(family: family, name: "Admitted Akahu", app_token: "app-test-token", user_token: "user-test-token")
        source = item.akahu_accounts.create!(account_id: "akahu-remote", name: "Admitted account", currency: "NZD", current_balance: 10)
        account = family.accounts.create!(name: "Financial account", balance: 10, currency: "NZD", accountable: Depository.new)
        AccountProvider.create!(account: account, provider: source)
        begin
          yield item, source, account
        ensure
          Account::SourcePolicy.where(account_id: account.id).delete_all
          AccountProvider.where(account_id: account.id).delete_all
          source.delete
          item.delete
          account.reload.destroy!
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end
end
