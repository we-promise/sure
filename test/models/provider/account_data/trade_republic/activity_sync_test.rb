require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::TradeRepublic::ActivitySyncTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Registry.stubs(:fetch).with("trade_republic").returns(Provider::AccountData::TradeRepublic)
  end

  test "durable topic and detail slices resume the same generation and checkpoint only after both accounts" do
    with_provider_encryption do
      connection, portfolio, cash = linked_connection
      sync = connection.syncs.create!
      client = mock("one connection timeline")
      client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).once.returns(response([ event ]))
      client.expects(:get_event_detail).with(event_id: "cash-event").once.returns(account: owner, response: {})
      client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).once.returns(response([]))
      2.times do
        assert_raises(Provider::AccountData::DeferredPage) { runner(connection, sync, client, budget: 1).perform }
        assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
        assert_empty SourceRecord.where(external_account: [ portfolio, cash ])
        assert_empty connection.provider_sync_generations.sole.children
      end
      generation = runner(connection, sync, client, budget: 1).perform
      assert generation.applied?
      assert_equal 3, generation.pages.count
      assert_equal 2, generation.children.where(status: "applied").count
      assert_equal 1, connection.provider_sync_generations.count
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "activities", scope_key: "connection")
      assert_equal generation.id, checkpoint.provider_sync_generation_id
      assert_equal generation.terminal_cursor, checkpoint.cursor
      assert_equal 1, cash.current_account.entries.where(external_id: "trade_republic_event_cash-event").count
      assert_empty portfolio.current_account.entries.where(external_id: "trade_republic_event_cash-event")
      assert_empty connection.provider_sync_checkpoints.where(stream: "holdings")
    end
  end

  test "failed child leaves sealed data and successful children intact without cursor promotion" do
    with_provider_encryption do
      connection, portfolio, cash = linked_connection
      sync = connection.syncs.create!
      client = empty_client
      failures = Class.new do
        define_method(:initialize) { |**values| @external = values.fetch(:external_account) }
        define_method(:apply) do |_page, **|
          raise Provider::AccountData::Error, "second child unavailable" if @external.external_id.start_with?("cash:")
        end
      end
      assert_raises(Provider::AccountData::Error) { runner(connection, sync, client, writer: failures).perform }
      generation = connection.provider_sync_generations.sole
      assert generation.sealed?
      assert_equal 1, generation.children.where(status: "applied").count
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
      unused = mock("no more HTTP after seal")
      unused.expects(:get_timeline_page).never
      assert runner(connection, sync, unused).perform.applied?
      assert_equal 2, generation.children.where(status: "applied").count
    end
  end

  test "another sync cannot inherit an unfinished original topic prefix" do
    with_provider_encryption do
      connection, = linked_connection
      first = connection.syncs.create!
      client = mock("initial topic")
      client.expects(:get_timeline_page).once.returns(response([]))
      assert_raises(Provider::AccountData::DeferredPage) { runner(connection, first, client, budget: 1).perform }
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, connection.syncs.create!, client).perform }
      assert_equal 1, connection.provider_sync_generations.count
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
    end
  end

  test "unproved cookie rotation prevents resumed HTTP and publication" do
    with_provider_encryption do
      connection, = linked_connection
      sync = connection.syncs.create!
      client = mock("initial topic")
      client.expects(:get_timeline_page).once.returns(response([]))
      assert_raises(Provider::AccountData::DeferredPage) { runner(connection, sync, client, budget: 1).perform }
      connection.update!(credentials: { "session_blob" => "unrecorded-new-cookie" })
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, sync, client).perform }
      assert_empty connection.provider_sync_generations.sole.children
    end
  end

  test "a source policy revision after capture cannot publish under the new owner" do
    with_provider_encryption do
      connection, portfolio, cash = linked_connection
      sync = connection.syncs.create!
      client = mock("initial topic")
      client.expects(:get_timeline_page).once.returns(response([]))
      assert_raises(Provider::AccountData::DeferredPage) { runner(connection, sync, client, budget: 1).perform }
      other = create_provider_connection
      alternative = create_external_account(other)
      link = AccountProvider.create!(account: cash.current_account, external_account: alternative)
      Account::SourcePolicy.select!(account: cash.current_account, account_provider: link, resource: "activities")
      client.expects(:get_timeline_page).once.returns(response([]))
      assert_raises(Provider::AccountData::StaleWriter) { runner(connection, sync, client).perform }
      assert_empty connection.provider_sync_generations.sole.children
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
    end
  end

  test "the public syncer defers before balance holdings or account jobs can rotate the retained session" do
    with_provider_encryption do
      connection, = linked_connection
      client = mock("initial topic")
      client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([]))
      adapter = build_adapter(client, budget: 1)
      page = Provider::AccountData::Page.new(records: %w[portfolio cash].map { |kind| adapter.normalize_account(owner, kind: kind) }, complete: true, mode: "snapshot")
      adapter.stubs(:list_accounts).returns(page)
      adapter.expects(:fetch_activities).never
      adapter.expects(:fetch_balance).never
      adapter.expects(:fetch_holdings).never
      Account.any_instance.expects(:sync_later).never
      assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert_nil connection.provider_sync_checkpoints.find_by(stream: "activities")
    end
  end

  test "database constraints prevent activity evidence and checkpoints from claiming a transaction generation resource" do
    with_provider_encryption do
      connection, = linked_connection
      generation = runner(connection, connection.syncs.create!, empty_client).perform
      child = generation.children.first
      assert_raises(ActiveRecord::InvalidForeignKey) do
        ApplicationRecord.transaction(requires_new: true) do
          child.update_columns(stream: "transactions", generation_resource: "transactions")
        end
      end
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "activities")
      assert_raises(ActiveRecord::InvalidForeignKey) do
        ApplicationRecord.transaction(requires_new: true) { checkpoint.update_columns(stream: "transactions") }
      end
    end
  end

  private
    def linked_connection
      connection = create_provider_connection(provider_key: "trade_republic", credentials: { "session_blob" => "original-cookie" })
      portfolio, cash = [ [ "DE123", accounts(:investment) ], [ "cash:DE123", accounts(:depository) ] ].map do |id, account|
        external = create_external_account(connection, external_id: id)
        link = AccountProvider.create!(account: account, external_account: external)
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: "activities")
        external
      end
      [ connection, portfolio, cash ]
    end

    def build_adapter(client, budget: 4)
      adapter = Provider::AccountData::TradeRepublic.new(client: client, timezone: "UTC", observed_at: Time.utc(2026, 9, 15),
        currency: "USD", linked_cash_ids: [ "cash:DE123" ])
      adapter.stubs(:activity_group_request_budget).returns(budget)
      adapter
    end

    def runner(connection, sync, client, budget: 4, writer: Ingestion::LedgerWriter)
      unless connection.lease_owner
        connection.update!(writer_epoch: [ connection.writer_epoch, 1 ].max, lease_owner: SecureRandom.uuid, lease_expires_at: 10.minutes.from_now)
      end
      Provider::AccountData::TransactionSync.new(connection: connection, sync: sync, adapter: build_adapter(client, budget: budget),
        resource: "activities", writer_epoch: connection.writer_epoch, fence: ->(&block) { connection.with_lock(&block) }, ledger_writer: writer)
    end

    def empty_client
      client = mock("empty two-topic timeline")
      client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([]))
      client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([]))
      client
    end

    def owner
      { securitiesAccountNumber: "DE123", currency: "USD" }
    end

    def event
      { id: "cash-event", timestamp: "2026-09-12T12:00:00Z", eventType: "INCOMING_TRANSFER", title: "Transfer", amount: { value: "10", currency: "USD" } }
    end

    def response(rows)
      { account: owner, response: { items: rows }, next_cursor: nil }
    end
end
