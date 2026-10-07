require "test_helper"
require "turbo/broadcastable/test_helper"

# #3630. A provider card lists every account on its connection, and a
# broadcast on the family stream is rendered with no viewer and reaches
# every member. No provider's sync completion may send it; the family sync
# toast makes each browser re-fetch its own, filtered page instead.
class ProviderItemSyncCompleteEventsTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  PROVIDERS = %w[
    binance_item coinspot_item fio_item ibkr_item indexa_capital_item kraken_item
    lunchflow_item mercury_item monobank_item plaid_item redbark_item
    snaptrade_item trade_republic_item trading212_item wise_item
  ].freeze

  PROVIDERS.each do |provider|
    test "a #{provider} sync completion sends the toast, not the card" do
      item = provider.camelize.constantize.first!
      Current.reset

      streams = capture_turbo_stream_broadcasts(item.family) do
        "#{provider.camelize}::SyncCompleteEvent".constantize.new(item).broadcast
      end
      targets = streams.map { |stream| stream["target"] }

      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      assert_includes targets, "sync-toast"
    end
  end

  # simplefin_items.yml is empty; SimpleFIN tests build their own item.
  test "a simplefin_item sync completion sends the toast, not the card" do
    item = families(:dylan_family).simplefin_items.create!(name: "SimpleFIN Connection", access_url: "https://example.com/access")
    Current.reset

    streams = capture_turbo_stream_broadcasts(item.family) do
      SimplefinItem::SyncCompleteEvent.new(item).broadcast
    end
    targets = streams.map { |stream| stream["target"] }

    assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
    assert_includes targets, "sync-toast"
  end

  # The two activity jobs used to send the card themselves once the delayed
  # activities arrived.
  { QuestradeActivitiesFetchJob => [ :questrade_accounts, :one, :questrade_item ],
    IndexaCapitalActivitiesFetchJob => [ :indexa_capital_accounts, :mutual_fund, :indexa_capital_item ] }.each do |job_class, (fixture, name, item_method)|
    test "#{job_class.name} sends the toast, not the card" do
      provider_account = send(fixture, name)
      item = provider_account.public_send(item_method)
      job = job_class.new
      job.instance_variable_set(:"@#{fixture.to_s.singularize}", provider_account)
      Current.reset

      streams = capture_turbo_stream_broadcasts(item.family) { job.send(:broadcast_updates) }
      targets = streams.map { |stream| stream["target"] }

      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      assert_includes targets, "sync-toast"
    end
  end
end
