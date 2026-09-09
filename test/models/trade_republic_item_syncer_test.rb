require "test_helper"

class TradeRepublicItemSyncerTest < ActiveSupport::TestCase
  setup do
    @item = trade_republic_items(:configured_item)
  end

  test "sync without session raises AuthenticationRequired and marks requires_update" do
    item = trade_republic_items(:no_session_item)
    sync = Sync.create!(syncable: item)

    assert_raises(Provider::TradeRepublicClient::AuthenticationRequired) do
      TradeRepublicItem::Syncer.new(item).perform_sync(sync)
    end

    assert item.reload.requires_update?
  end

  test "authentication errors mark the item requires_update" do
    sync = Sync.create!(syncable: @item)
    @item.stubs(:import_latest_data).raises(Provider::TradeRepublicClient::LoginExpired, "login expired")

    assert_raises(Provider::TradeRepublicClient::LoginExpired) do
      TradeRepublicItem::Syncer.new(@item).perform_sync(sync)
    end

    assert @item.reload.requires_update?
    assert_match(/expired/, sync.reload.sync_stats.dig("errors", 0, "message").to_s)
  end

  test "successful sync imports data and collects health stats" do
    sync = Sync.create!(syncable: @item)

    result = client_result(
      "status" => "ok",
      "session_txt" => "# refreshed",
      "account" => { "brokerage_account_id" => "DESYNC1", "currency" => "EUR" },
      "cash" => { "amount" => "10.00", "currency" => "EUR" },
      "positions" => [],
      "events" => [],
      "newest_event_id" => nil,
      "warnings" => []
    )

    provider = mock("trade_republic_provider")
    provider.expects(:sync).returns(result)
    Provider::TradeRepublicClient.any_instance.stubs(:sync).returns(result)

    @item.stubs(:trade_republic_provider).returns(provider)

    TradeRepublicItem::Syncer.new(@item).perform_sync(sync)

    assert_not_nil @item.trade_republic_accounts.find_by(trade_republic_account_id: "DESYNC1")
  end

  private

    def client_result(data)
      Provider::TradeRepublicClient::Result.new(data: data)
    end
end
