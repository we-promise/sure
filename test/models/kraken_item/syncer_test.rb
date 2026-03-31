require "test_helper"

class KrakenItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @kraken_item = KrakenItem.create!(
      family: @family,
      name: "Test Kraken Connection",
      api_key: "test_api_key_123",
      api_secret: "test_api_secret_123"
    )
    @syncer = KrakenItem::Syncer.new(@kraken_item)
  end

  test "perform_sync imports data from kraken api" do
    mock_sync = build_sync_mock

    @kraken_item.expects(:import_latest_kraken_data).once

    @syncer.perform_sync(mock_sync)
  end

  test "perform_sync updates pending_account_setup when unlinked accounts exist" do
    @kraken_item.kraken_accounts.create!(
      name: "Unlinked Balance",
      currency: "USD"
    )

    mock_sync = build_sync_mock

    @kraken_item.expects(:import_latest_kraken_data).once
    @syncer.perform_sync(mock_sync)

    assert @kraken_item.reload.pending_account_setup?
  end

  test "perform_sync processes accounts when linked accounts exist" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    kraken_account = @kraken_item.kraken_accounts.create!(
      name: "Linked Balance",
      currency: "USD"
    )
    AccountProvider.create!(account: account, provider: kraken_account)

    mock_sync = build_sync_mock

    @kraken_item.expects(:import_latest_kraken_data).once
    @kraken_item.expects(:process_accounts).once
    @kraken_item.expects(:schedule_account_syncs).with(
      parent_sync: mock_sync,
      window_start_date: nil,
      window_end_date: nil
    ).once

    @syncer.perform_sync(mock_sync)
  end

  private
    def build_sync_mock
      mock("sync").tap do |mock_sync|
        mock_sync.stubs(:respond_to?).with(:status_text).returns(true)
        mock_sync.stubs(:respond_to?).with(:sync_stats).returns(true)
        mock_sync.stubs(:sync_stats).returns({})
        mock_sync.stubs(:window_start_date).returns(nil)
        mock_sync.stubs(:window_end_date).returns(nil)
        mock_sync.stubs(:created_at).returns(Time.current)
        mock_sync.expects(:update!).at_least_once
      end
    end
end
