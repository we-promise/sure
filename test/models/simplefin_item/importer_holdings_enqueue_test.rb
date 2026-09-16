require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::ImporterHoldingsEnqueueTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    ApplicationController.stubs(:render).returns("card")
    Turbo::StreamsChannel.stubs(:broadcast_replace_to)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "each changed response enqueues its signed snapshot and only the latest request can publish" do
    with_source do |item, source, sync, account, security|
      provider = mock("discovery and changed holdings")
      provider.expects(:get_accounts).twice.returns(
        response(source, security, market_value: "100"),
        response(source, security, market_value: "200"))
      enqueued = capture_enqueue do |captured_source, position|
        assert_equal source.id, captured_source.id
        assert_equal (position == 1 ? "100" : "200"), captured_source.raw_holdings_payload.sole.fetch("market_value")
      end

      SimplefinHoldingsApplyJob.stub(:perform_later, enqueued.fetch(:capture)) do
        SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).import
      end

      requests = enqueued.fetch(:requests)
      assert_equal 2, requests.size
      assert_equal [ source.id, source.id ], requests.map { |row| row.fetch(:source_id) }
      refute_equal requests.first.fetch(:request), requests.last.fetch(:request)
      assert_equal BigDecimal("100"), account.reload.cash_balance
      assert_equal 2, sync.reload.sync_stats.fetch("api_requests")
      assert_empty account.holdings

      # This exercises the actual delayed job and request verifier: a newer
      # cache cannot silently become the input of the first queued request.
      assert_raises(Fence::OwnershipChanged) do
        SimplefinHoldingsApplyJob.perform_now(source.id, request: requests.first.fetch(:request))
      end
      assert_empty account.holdings

      resolver = Object.new
      lookup = -> { assert_equal 0, ApplicationRecord.connection.open_transactions }
      resolver.define_singleton_method(:resolve) do
        lookup.call
        security
      end
      Security::Resolver.expects(:new).once.with(security.ticker).returns(resolver)
      SimplefinHoldingsApplyJob.perform_now(source.id, request: requests.last.fetch(:request))

      holding = account.holdings.find_by!(external_id: "simplefin_holding")
      assert_equal BigDecimal("2"), holding.qty
      assert_equal BigDecimal("200"), holding.amount
      assert_equal BigDecimal("100"), holding.price
      assert_equal security.id, holding.security_id
      assert_equal source.reload.account_provider.id, holding.account_provider_id
      assert_equal Date.current, holding.date
      assert_equal 1, account.holdings.count
    end
  end

  test "an unchanged regular snapshot needs one request which remains bound to its originating Sync" do
    with_source do |item, source, sync, account, security|
      provider = mock("discovery and unchanged holdings")
      payload = response(source, security, market_value: "100")
      provider.expects(:get_accounts).twice.returns(payload, payload.deep_dup)
      enqueued = capture_enqueue

      SimplefinHoldingsApplyJob.stub(:perform_later, enqueued.fetch(:capture)) do
        SimplefinItem::Importer.new(item, simplefin_provider: provider, sync: sync).import
      end

      request = enqueued.fetch(:requests).sole.fetch(:request)
      assert_equal 2, sync.reload.sync_stats.fetch("api_requests")
      assert_equal BigDecimal("200"), account.reload.cash_balance
      SimplefinAccount::HoldingsRequest.from_token(request, source_id: source.id).with_source do |fresh|
        assert_equal source.id, fresh.id
      end

      replacement = item.syncs.create!
      sync.update_columns(cancel_requested_at: Time.current)
      before_account = account.reload.attributes
      SimplefinAccount::Investments::HoldingsProcessor.expects(:new).never

      assert_raises(Fence::OwnershipChanged) do
        SimplefinHoldingsApplyJob.perform_now(source.id, request: request)
      end

      assert replacement.reload.pending?
      assert_equal before_account, account.reload.attributes
      assert_empty account.holdings
      assert sync.reload.cancel_requested_at.present?
    end
  end

  private

    def capture_enqueue(&on_capture)
      requests = []
      capture = lambda do |source_id, request:|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_kind_of String, request
        assert request.present?
        SimplefinAccount::HoldingsRequest.from_token(request, source_id: source_id).with_source do |source|
          on_capture&.call(source, requests.size + 1)
        end
        requests << { source_id: source_id, request: request }
        nil
      end
      { capture: capture, requests: requests }
    end

    def response(source, security, market_value:)
      { accounts: [ { id: source.account_id, name: source.name, type: "investment", currency: "USD", balance: "300",
        holdings: [ { id: "holding", symbol: security.ticker, quantity: "2", market_value: market_value, currency: "USD" } ] } ],
        errors: [] }.with_indifferent_access
    end

    def with_source
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN importer holdings requests")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/access",
          last_synced_at: 1.day.ago)
        security = Security.create!(ticker: "SF#{SecureRandom.hex(5).upcase}", name: "Import request security", offline: true)
        source = item.simplefin_accounts.create!(name: "Brokerage", account_id: SecureRandom.uuid,
          account_type: "investment", currency: "USD", current_balance: 100,
          raw_transactions_payload: [ { "id" => "retained" } ])
        account = Account.create!(family: family, name: "Brokerage", currency: "USD", balance: 100,
          cash_balance: 100, accountable: Investment.new)
        AccountProvider.create!(account: account, provider: source)
        sync = item.syncs.create!
        yield item, source, sync, account, security
      ensure
        if family&.persisted?
          Holding.where(account_id: family.accounts.select(:id)).find_each(&:destroy!)
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.reload.each(&:destroy!)
          item&.reload&.destroy!
          family.destroy!
        end
        security&.destroy!
      end
    end
end
