require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::ImporterAdmissionRegressionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    ApplicationController.stubs(:render).returns("card")
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "public discovery Syncer preserves importer balances-only stats and the initial history timestamp" do
    with_source(linked: false) do |item, source, sync, _account|
      provider = mock("balances discovery")
      SimplefinItem.any_instance.stubs(:simplefin_provider).returns(provider)
      provider.expects(:get_accounts).once.returns(response(source))
      assert_nil sync.sync_stats

      Fence.with_item(item, operation: :sync) do |current|
        SimplefinItem::Syncer.new(current).perform_sync(sync)
      end

      assert sync.reload.completed?
      assert_equal true, sync.sync_stats.fetch("balances_only")
      assert_equal 1, sync.sync_stats.fetch("api_requests")
      assert_equal 1, sync.sync_stats.fetch("unlinked_accounts")
      assert_nil item.reload.last_synced_at
      assert item.pending_account_setup?
    end
  end

  test "both public importer modes reject a foreign financial link after saving the source snapshot" do
    [ :import_balances_only, :import ].each do |method|
      with_source do |item, source, sync, account|
        account.update_columns(family_id: families(:empty).id)
        before_account = account.reload.attributes
        provider = mock("account discovery")
        provider.expects(:get_accounts).once.returns(response(source))
        Account::ProviderImportAdapter.expects(:new).never
        SimplefinAccount::PendingCleanup.expects(:new).never
        SimplefinHoldingsApplyJob.expects(:enqueue_for).never

        assert_raises(Fence::OwnershipChanged) do
          SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).public_send(method)
        end

        assert_equal before_account, account.reload.attributes
        assert_equal BigDecimal("300"), source.reload.current_balance
        refute sync.reload.sync_stats.key?("accounts_skipped")
        refute sync.sync_stats.key?("errors")
      end
    end
  end

  test "a post-save parent change is rejected without acquiring another item permit" do
    with_source do |item, source, sync, account|
      other = SimplefinItem.create!(family: item.family, name: "Replacement owner", access_url: "https://example.com/other")
      provider = mock("account discovery")
      provider.expects(:get_accounts).once.returns(response(source))
      SimplefinAccount::PendingCleanup.expects(:new).never
      before_account = account.reload.attributes
      callback = -> { SimplefinAccount.where(id: id).update_all(simplefin_item_id: other.id) if id == source.id }
      SimplefinAccount.set_callback(:update, :after, callback)

      assert_raises(Fence::OwnershipChanged) do
        SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).import
      end
      assert_equal before_account, account.reload.attributes
      refute sync.reload.sync_stats.key?("accounts_skipped")
    ensure
      SimplefinAccount.skip_callback(:update, :after, callback) if callback
      source&.update_columns(simplefin_item_id: item.id)
      other&.delete
    end
  end

  test "nested financial denials escape both importer modes without recovery stats or follow-up work" do
    [ :import_balances_only, :import ].each do |method|
      SimplefinItem::LegacyAccess::DENIAL_ERRORS.each do |error_class|
        with_source do |item, source, sync, account|
          provider = mock("account discovery")
          provider.expects(:get_accounts).once.returns(response(source))
          before_account = account.reload.attributes
          before_denial = nil
          failure = error_class.new("Denied financial publication")
          denied = lambda do |*args, **kwargs|
            before_denial = Sync.find(sync.id).sync_stats
            raise failure
          end
          SimplefinHoldingsApplyJob.expects(:enqueue_for).never

          operation = -> { SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).public_send(method) }
          caught = if method == :import_balances_only
            adapter = Account::ProviderImportAdapter.new(account)
            Account::ProviderImportAdapter.stub(:new, adapter) do
              adapter.stub(:update_balance, denied) { assert_raises(error_class, &operation) }
            end
          else
            cleanup = SimplefinAccount::PendingCleanup.new(source, expected_account: account)
            SimplefinAccount::PendingCleanup.stub(:new, cleanup) do
              cleanup.stub(:call, denied) { assert_raises(error_class, &operation) }
            end
          end

          assert_same failure, caught
          assert before_denial
          assert_equal before_denial, sync.reload.sync_stats
          assert_equal before_account, account.reload.attributes
        end
      end
    end
  end

  test "both importer modes reject unlink at publication without balance changes or follow-up jobs" do
    [ :import_balances_only, :import ].each do |method|
      with_source do |item, source, sync, account|
        provider = mock("discovery interrupted by unlink")
        provider.expects(:get_accounts).once.returns(response(source))
        before = account.reload.attributes
        original = SimplefinItem::LegacyAccess.method(:with_publication)
        changed = lambda do |selected, expected_account:, &block|
          AccountProvider.where(account_id: account.id).delete_all
          original.call(selected, expected_account: expected_account, &block)
        end
        SimplefinHoldingsApplyJob.expects(:enqueue_for).never

        SimplefinItem::LegacyAccess.stub(:with_publication, changed) do
          assert_raises(Fence::OwnershipChanged) do
            SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).public_send(method)
          end
        end

        assert_equal before, account.reload.attributes
        assert_empty account.entries
        assert_not account.linked?
        refute sync.reload.sync_stats.key?("accounts_skipped")
        refute sync.sync_stats.key?("errors")
      end
    end
  end

  test "readmission reconciles once and enqueues each changed holdings snapshot across both responses" do
    with_source do |item, source, sync, account|
      item.update_columns(last_synced_at: 1.day.ago)
      source.update_columns(raw_transactions_payload: [ { "id" => "retained" } ])
      provider = mock("discovery and regular response")
      first = response(source, holding_value: 100)
      second = response(source, holding_value: 200)
      provider.expects(:get_accounts).twice.returns(first, second)
      cleanup = mock("once-per-import pending cleanup")
      SimplefinAccount::PendingCleanup.expects(:new).once.with(source, expected_account: account).returns(cleanup)
      cleanup.expects(:call).once.yields(kind: :finished, account_id: account.id, success: true).returns(true)
      SimplefinHoldingsApplyJob.expects(:enqueue_for).twice.with(source, sync: sync)

      SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).import

      assert_equal BigDecimal("100"), account.reload.cash_balance
      assert_equal 2, sync.reload.sync_stats.fetch("api_requests")
      assert_equal 1, sync.sync_stats.fetch("total_accounts")
    end
  end

  private

    def with_source(linked: true)
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN importer admission")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access")
        source = item.simplefin_accounts.create!(name: "Brokerage", account_id: SecureRandom.uuid,
          account_type: "investment", currency: "USD", current_balance: 100)
        sync = item.syncs.create!
        if linked
          account = Account.create!(family: family, name: "Investment", currency: "USD", balance: 100,
            cash_balance: 100, accountable: Investment.new)
          AccountProvider.create!(account: account, provider: source)
        end
        yield item, source, sync, account
      ensure
        AccountProvider.where(account_id: account.id).delete_all if account
        if account
          accountable = account.accountable
          account.delete
          accountable.delete
        end
        sync&.delete
        source&.delete
        item&.delete
        family&.delete
      end
    end

    def response(source, holding_value: 100)
      {
        accounts: [ {
          id: source.account_id, name: "Brokerage", type: "investment", currency: "USD", balance: 300,
          holdings: [ { id: "holding", symbol: "AAPL", quantity: 1, market_value: holding_value, currency: "USD" } ]
        } ], errors: []
      }.with_indifferent_access
    end
end
