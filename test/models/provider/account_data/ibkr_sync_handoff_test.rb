require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::IbkrSyncHandoffTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    DebugLogEntry.stubs(:capture)
    # IBKR must use the sealed handoff, never the generic scheduling fallback.
    Account.any_instance.expects(:sync_later).never
  end

  test "only completed inventory and account streams reach the exact export handoff" do
    with_provider_encryption do
      connection, external = linked_connection
      sync = connection.syncs.create!
      adapter = complete_adapter(external)
      handoff = mock("sealed IBKR account dispatcher")
      handoff.expects(:enqueue!).once
      Provider::AccountData::Ibkr::AccountHandoff.expects(:new).with do |arguments|
        assert_equal connection, arguments[:connection]
        assert_equal sync, arguments[:sync]
        assert_equal external, arguments[:external_account]
        assert_equal connection.reload.writer_epoch, arguments[:writer_epoch]
        assert_respond_to arguments[:fence], :call
        checkpoints = connection.provider_sync_checkpoints.includes(:ingestion_batch)
        assert_equal %w[accounts activities balances holdings], checkpoints.map(&:stream).sort
        assert checkpoints.all? { |checkpoint| checkpoint.ingestion_batch.complete? && checkpoint.ingestion_batch.applied? }
        true
      end.returns(handoff)

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
    end
  end

  test "failure in any required account stream cannot schedule historical materialization" do
    with_provider_encryption do
      %i[fetch_balance fetch_holdings fetch_activities].each do |failed_method|
        connection, external = linked_connection
        adapter = complete_adapter(external)
        adapter.stubs(failed_method).raises(Provider::AccountData::InvalidResponse, "Unusable account stream")
        Provider::AccountData::Ibkr::AccountHandoff.expects(:new).never
        sync = connection.syncs.create!

        assert_raises(Provider::AccountData::Error) do
          Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)
        end
        assert_empty sync.children
      end
    end
  end

  test "partial inventory does not authorize a historical account handoff" do
    with_provider_encryption do
      connection, external = linked_connection
      adapter = complete_adapter(external)
      adapter.stubs(:list_accounts).returns(account_page(external, complete: false))
      Provider::AccountData::Ibkr::AccountHandoff.expects(:new).never

      assert_raises(Provider::AccountData::IncompletePage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      assert connection.provider_sync_checkpoints.where(stream: "activities").exists?
      assert_not connection.provider_sync_checkpoints.where(stream: "accounts").exists?
    end
  end

  test "deferred account work retains its continuation and does not hand off history" do
    with_provider_encryption do
      connection, external = linked_connection
      adapter = complete_adapter(external)
      adapter.stubs(:fetch_activities).returns(Provider::AccountData::Page.new(records: [], complete: false,
        progress_cursor: "later-activity-slice", coverage: { "available_at" => 1.minute.from_now.iso8601 }))
      Provider::AccountData::Ibkr::AccountHandoff.expects(:new).never

      assert_raises(Provider::AccountData::DeferredPage) do
        Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(connection.syncs.create!)
      end
      checkpoint = connection.provider_sync_checkpoints.find_by!(stream: "activities")
      assert_equal "later-activity-slice", checkpoint.state.dig("progress", "cursor")
    end
  end

  test "cancellation during the final account request prevents handoff" do
    with_provider_encryption do
      connection, external = linked_connection
      sync = connection.syncs.create!(status: "syncing")
      adapter = complete_adapter(external)
      adapter.define_singleton_method(:fetch_activities) do |**_arguments|
        sync.update_columns(cancel_requested_at: Time.current)
        Provider::AccountData::Page.new(records: [], complete: true)
      end
      Provider::AccountData::Ibkr::AccountHandoff.expects(:new).never

      Provider::AccountData::Syncer.new(connection, adapter: adapter).perform_sync(sync)

      assert_empty sync.children
    end
  end

  private
    def linked_connection
      connection = create_provider_connection(provider_key: "ibkr", credentials: { "query_id" => "test-query", "token" => "test-token" })
      external = create_external_account(connection, external_id: "U1234")
      account = Account.create!(family: connection.family, name: "IBKR calculation", currency: "USD",
        balance: 0, accountable: Investment.create!)
      link = AccountProvider.create!(account: account, external_account: external)
      %w[balances holdings activities historical_balances].each do |resource|
        Account::SourcePolicy.select!(account: account, account_provider: link, resource: resource)
      end
      [ connection, external ]
    end

    def account_page(external, complete: true)
      record = Ingestion::Record.account(external_id: external.external_id, name: "IBKR account", currency: "USD")
      Provider::AccountData::Page.new(records: [ record ], complete: complete, mode: "snapshot")
    end

    def complete_adapter(external)
      adapter = stub(capabilities: %w[holdings activities])
      adapter.stubs(:list_accounts).returns(account_page(external))
      adapter.stubs(:fetch_balance).returns(account_page(external))
      adapter.stubs(:fetch_holdings).returns(Provider::AccountData::Page.new(records: [], complete: true))
      adapter.stubs(:fetch_activities).returns(Provider::AccountData::Page.new(records: [], complete: true))
      adapter
    end
end
