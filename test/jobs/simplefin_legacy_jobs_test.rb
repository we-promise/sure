require "test_helper"
require "timeout"
require_relative "../support/provider_ingestion_test_helper"

class SimplefinLegacyJobsTest < ActiveJob::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "all deferred jobs reject quiescing and native owners before work or recovery" do
    with_item do |item, source, account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "quiescing")
      item.update_columns(scheduled_for_deletion: true)
      SimplefinItem.any_instance.expects(:simplefin_provider).never
      SimplefinItem::Importer.expects(:new).never
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never
      ApplicationController.expects(:render).never
      before = [ item.reload.attributes, source.reload.attributes, account.reload.attributes ]

      %w[quiescing active retired].each do |state|
        control.update!(state: state)
        deferred_jobs(item, source, request: request, claim: claim).each do |job|
          assert_no_enqueued_jobs { assert_raises(Fence::OwnershipChanged, &job) }
        end
        assert_equal before, [ item.reload.attributes, source.reload.attributes, account.reload.attributes ]
      end
    end
  end

  test "a competing drain blocks every job and leaves credentials and flags untouched" do
    with_item do |item, source, account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      before = [ item.reload.attributes, source.reload.attributes, account.reload.attributes ]
      SimplefinItem.any_instance.expects(:simplefin_provider).never
      ApplicationController.expects(:render).never
      with_rowless_drain(item) do
        deferred_jobs(item, source, request: request, claim: claim).each do |job|
          assert_no_enqueued_jobs { assert_raises(Fence::Busy, &job) }
        end
      end
      assert_equal before, [ item.reload.attributes, source.reload.attributes, account.reload.attributes ]
    end
  end

  test "holdings application verifies the captured payload and keeps admission during processing" do
    with_item do |item, source, _account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      processor = mock("holdings processor")
      processor.expects(:process).once
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).with do |current, **options|
        assert_equal source.id, current.id
        assert_equal [ { "id" => "original" } ], current.raw_holdings_payload
        assert_kind_of SimplefinAccount::HoldingsRequest, options.fetch(:request)
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, try_drain(item)
        true
      end.returns(processor)

      SimplefinHoldingsApplyJob.perform_now(source.id, request: request)
      assert_equal :drained, try_drain(item)
    end
  end

  test "holdings application refuses a changed payload instead of upgrading the queued request" do
    with_item do |_item, source, _account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never
      before_first_admission(-> { source.update_columns(raw_holdings_payload: [ { "id" => "fresh-holding" } ]) }) do
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: request) }
      end
    end
  end

  test "holdings application rejects a source reparented between selection and admission" do
    with_item do |item, source, _account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      other = SimplefinItem.create!(family: item.family, name: "Other source", access_url: "https://example.com/other")
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never

      before_first_admission(-> { source.update_columns(simplefin_item_id: other.id) }) do
        assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: request) }
      end
    ensure
      source&.update_columns(simplefin_item_id: item.id)
      other&.delete
    end
  end

  test "holdings application rejects a cross-family financial link" do
    with_item do |_item, source, account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      account.update_columns(family_id: families(:empty).id)
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never

      assert_raises(Fence::OwnershipChanged) { SimplefinHoldingsApplyJob.perform_now(source.id, request: request) }
    end
  end

  test "holdings ordinary failure is recorded inside admission with sanitized source context" do
    with_item do |item, source, account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      processor = mock("failed holdings processor")
      SimplefinAccount::Investments::HoldingsProcessor.stubs(:new).returns(processor)
      processor.expects(:process).raises(StandardError, "private payload")
      DebugLogEntry.expects(:capture).with do |attributes|
        assert_equal :busy, try_drain(item)
        assert_equal item.family_id, attributes.fetch(:family).id
        assert_equal account.id, attributes.fetch(:account).id
        assert_equal source.id, attributes.fetch(:metadata).fetch(:simplefin_account_id)
        assert_not_includes attributes.inspect, "private payload"
        true
      end

      SimplefinHoldingsApplyJob.perform_now(source.id, request: request)
      assert_equal :drained, try_drain(item)
    end
  end

  test "balances discovery receives fresh credentials and refreshes without advancing history" do
    with_item do |item, _source, _account|
      importer = mock("balances importer")
      SimplefinItem::Importer.expects(:new).with do |current|
        assert_equal item.id, current.id
        assert_equal "https://example.com/fresh", current.access_url
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal :busy, try_drain(item)
        true
      end.returns(importer)
      importer.expects(:import_balances_only).once
      expect_broadcast(item)

      before_first_admission(-> { item.update_columns(access_url: "https://example.com/fresh") }) do
        SimplefinItem::BalancesOnlyJob.perform_now(item.id)
      end
      assert_nil item.reload.last_synced_at
      assert_equal :drained, try_drain(item)
    end
  end

  test "ordinary discovery failure still refreshes the family within admission" do
    with_item do |item, _source, _account|
      importer = mock("failed balances importer")
      SimplefinItem::Importer.stubs(:new).returns(importer)
      importer.expects(:import_balances_only).raises(StandardError, "private access URL")
      DebugLogEntry.expects(:capture).with do |attributes|
        assert_equal :busy, try_drain(item)
        assert_equal item.family_id, attributes.fetch(:family).id
        assert_not_includes attributes.inspect, "private access URL"
        true
      end
      expect_broadcast(item)

      SimplefinItem::BalancesOnlyJob.perform_now(item.id)
      assert_nil item.reload.last_synced_at
    end
  end

  test "nested job ownership denials cannot become best-effort success" do
    with_item do |item, source, _account|
      request = SimplefinAccount::HoldingsRequest.capture(source)
      processor = mock("holdings processor")
      importer = mock("balances importer")
      SimplefinAccount::Investments::HoldingsProcessor.stubs(:new).returns(processor)
      SimplefinItem::Importer.stubs(:new).returns(importer)
      ApplicationController.expects(:render).never
      DebugLogEntry.expects(:capture).never

      [ Fence::Busy, Fence::OwnershipChanged, Fence::InvalidSource ].each do |error_class|
        processor.expects(:process).raises(error_class, "denied")
        importer.expects(:import_balances_only).raises(error_class, "denied")
        claim_id = SecureRandom.uuid
        SimplefinItem::ConnectionUpdate.expects(:perform).with(claim_id: claim_id, family_id: item.family_id)
          .raises(error_class, "denied")
        assert_raises(error_class) { SimplefinHoldingsApplyJob.perform_now(source.id, request: request) }
        assert_raises(error_class) { SimplefinItem::BalancesOnlyJob.perform_now(item.id) }
        assert_raises(error_class) do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim_id)
        end
      end
    end
  end

  test "ownership denial while rendering discovery results escapes the broadcast recovery" do
    with_item do |item, _source, _account|
      importer = mock("balances importer")
      SimplefinItem::Importer.stubs(:new).returns(importer)
      importer.expects(:import_balances_only).once
      ApplicationController.expects(:render).raises(Fence::OwnershipChanged, "denied")
      Turbo::StreamsChannel.expects(:broadcast_replace_to).never
      Family.any_instance.expects(:broadcast_refresh).never
      DebugLogEntry.expects(:capture).never

      assert_raises(Fence::OwnershipChanged) { SimplefinItem::BalancesOnlyJob.perform_now(item.id) }
    end
  end

  test "connection update holds admission during token claim and follow-up scheduling" do
    with_item do |item, source, account|
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      provider = mock("SimpleFIN token claim")
      SimplefinItem.any_instance.expects(:simplefin_provider).with do
        assert_equal :busy, try_drain(item)
        assert_equal 0, ApplicationRecord.connection.open_transactions
        true
      end.returns(provider)
      provider.expects(:claim_access_url).with(setup_token).returns("https://example.com/reconnected")
      SyncJob.expects(:perform_later).with do |sync|
        assert_equal :busy, try_drain(item)
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal "https://example.com/reconnected", item.reload.access_url
        assert_equal item.id, sync.syncable_id
        assert_equal claim.reload.sync_id, sync.id
        true
      end

      SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)

      assert_equal "https://example.com/reconnected", item.reload.access_url
      assert_equal account.id, source.reload.current_account.id
      assert_equal :drained, try_drain(item)
    end
  end

  test "failed single-use token claim retains its discard behavior and never schedules a retry" do
    with_item do |item, _source, _account|
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      provider = mock("failed SimpleFIN token claim")
      SimplefinItem.any_instance.stubs(:simplefin_provider).returns(provider)
      provider.expects(:claim_access_url).raises(Provider::Simplefin::SimplefinError, "private setup token")
      SyncJob.expects(:perform_later).never
      DebugLogEntry.expects(:capture).with do |attributes|
        assert_equal :busy, try_drain(item)
        assert_not_includes attributes.inspect, "private setup token"
        true
      end

      assert_no_enqueued_jobs do
        SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
      end
      assert_equal "https://example.com/original", item.reload.access_url
      assert claim.reload.uncertain?
    end
  end

  test "connection update refuses a foreign family before consuming a setup token" do
    with_item do |item, _source, _account|
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      SimplefinItem.any_instance.expects(:simplefin_provider).never
      assert_raises(ActiveRecord::RecordNotFound) do
        SimplefinConnectionUpdateJob.perform_now(family_id: families(:empty).id, claim_id: claim.id)
      end
    end
  end

  test "missing deferred source rows remain no-ops" do
    SimplefinItem::Importer.expects(:new).never
    SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never
    SimplefinHoldingsApplyJob.perform_now(SecureRandom.uuid)
    SimplefinItem::BalancesOnlyJob.perform_now(SecureRandom.uuid)
  end

  private

    def with_item
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN deferred job test")
        item = SimplefinItem.create!(family: family, name: "Deferred SimpleFIN", access_url: "https://example.com/original")
        source = item.simplefin_accounts.create!(name: "Investment", account_id: SecureRandom.uuid,
          currency: "USD", account_type: "investment", current_balance: 100, raw_holdings_payload: [ { "id" => "original" } ])
        account = Account.create!(family: family, name: "Investment", currency: "USD", balance: 100, accountable: Investment.new)
        AccountProvider.create!(account: account, provider: source)
        yield item, source, account
      ensure
        ProviderCredentialClaim.where(family_id: family.id).delete_all if family
        AccountProvider.where(account_id: account.id).delete_all if account
        if account
          accountable = account.accountable
          account.delete
          accountable.delete
        end
        source&.delete
        item.syncs.destroy_all if item&.persisted?
        ProviderMigrationControl.where(legacy_type: "SimplefinItem", legacy_id: item.id).delete_all if item
        item&.delete
        family&.delete
      end
    end

    def deferred_jobs(item, source, request:, claim:)
      [
        -> { SimplefinHoldingsApplyJob.perform_now(source.id, request: request) },
        -> { SimplefinItem::BalancesOnlyJob.perform_now(item.id) },
        -> { SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id) }
      ]
    end

    def setup_token
      Base64.strict_encode64("https://example.com/single-use-token")
    end

    def before_first_admission(change, &block)
      original = Fence.method(:with_item)
      changed = false
      wrapper = lambda do |item, **options, &admitted|
        unless changed
          changed = true
          change.call
        end
        original.call(item, **options, &admitted)
      end
      Fence.stub(:with_item, wrapper, &block)
    end

    def expect_broadcast(item)
      ApplicationController.expects(:render).with do |options|
        assert_equal item.id, options.fetch(:locals).fetch(:simplefin_item).id
        assert_equal :busy, try_drain(item)
        true
      end.returns("card")
      Turbo::StreamsChannel.expects(:broadcast_replace_to).with do |family, **options|
        assert_equal item.family_id, family.id
        assert_equal "card", options.fetch(:html)
        assert_equal :busy, try_drain(item)
        true
      end
      Family.any_instance.expects(:broadcast_refresh).once
    end

    def try_drain(item)
      in_another_session do
        Fence.with_exclusive(item) { :drained }
      rescue Fence::Busy
        :busy
      end
    end

    def with_rowless_drain(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        Fence.with_exclusive(item) do
          entered << true
          release.pop
        end
      end
      Timeout.timeout(5) { entered.pop }
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new(&block)
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
