require "test_helper"
require "turbo/broadcastable/test_helper"

# #3630. A provider card lists every account on its connection, and a
# broadcast on the family stream is rendered with no viewer and reaches
# every member. No provider's sync completion may send it; the family sync
# toast makes each browser re-fetch its own, filtered page instead.
class ProviderItemSyncCompleteEventsTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  PROVIDERS = %w[
    binance_item brex_item coinspot_item fio_item ibkr_item indexa_capital_item kraken_item
    lunchflow_item mercury_item monobank_item plaid_item questrade_item redbark_item
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

  # Providers without fixtures, built with only what their validations need.
  {
    "akahu_item" => { app_token: "app", user_token: "user" },
    "coinbase_item" => { api_key: "key", api_secret: "secret" },
    "coinstats_item" => { api_key: "key" },
    "sharesight_item" => { client_id: "client", client_secret: "secret" },
    "sophtron_item" => { user_id: "user", access_key: "key" },
    "up_item" => { access_token: "token" }
  }.each do |provider, attributes|
    test "a #{provider} sync completion sends the toast, not the card" do
      item = families(:dylan_family).public_send(provider.pluralize).create!(name: "Connection", **attributes)
      Current.reset

      streams = capture_turbo_stream_broadcasts(item.family) do
        "#{provider.camelize}::SyncCompleteEvent".constantize.new(item).broadcast
      end
      targets = streams.map { |stream| stream["target"] }

      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      assert_includes targets, "sync-toast"
    end
  end

  # Post-sync runs the provider's event, so a missing class raised NameError
  # there and nothing was broadcast.
  { "brex_item" => :import_latest_brex_data,
    "questrade_item" => :import_latest_questrade_data,
    "sharesight_item" => :import_latest_data }.each do |provider, import|
    test "a completed #{provider} sync refreshes each linked account and sends the toast, not the card" do
      item, linked_accounts = connection_with_linked_accounts(provider)
      item.class.any_instance.stubs(import).returns(true)
      item.class.any_instance.stubs(:process_accounts).returns([])
      # No child account syncs, so the connection's post-sync runs within perform.
      item.class.any_instance.stubs(:schedule_account_syncs).returns([])
      captured = []
      Current.reset

      Sentry.stub(:capture_exception, ->(exception, *) { captured << exception.class.name }) do
        Sync.create!(syncable: item).perform
      end
      targets = capture_turbo_stream_broadcasts(item.family).map { |stream| stream["target"] }

      assert_equal [], captured
      assert_includes targets, "sync-toast"
      assert_not_includes targets, ActionView::RecordIdentifier.dom_id(item)
      linked_accounts.each do |account|
        assert_equal [ "refresh" ], capture_turbo_stream_broadcasts(account).map { |stream| stream["action"] }, account.name
      end
      assert_empty capture_turbo_stream_broadcasts(accounts(:depository))
    end
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

  private
    # The connection and its two linked accounts.
    def connection_with_linked_accounts(provider)
      family = families(:dylan_family)
      accounts = 2.times.map do |i|
        family.accounts.create!(name: "Linked #{provider} #{i}", balance: 0, currency: "USD", accountable: Investment.new)
      end

      case provider
      when "brex_item"
        item = brex_items(:one)
        provider_accounts = [ brex_accounts(:checking_account), item.brex_accounts.create!(name: "Brex Card", currency: "USD", account_id: "card_2", account_kind: "card") ]
      when "questrade_item"
        item = questrade_items(:one)
        provider_accounts = [ questrade_accounts(:one), item.questrade_accounts.create!(name: "RRSP", currency: "CAD", questrade_account_id: "87654321") ]
      when "sharesight_item"
        item = family.sharesight_items.create!(name: "Sharesight", client_id: "client", client_secret: "secret")
        provider_accounts = 2.times.map { |i| item.sharesight_accounts.create!(name: "Shares #{i}", currency: "USD", sharesight_account_id: i.to_s) }
      end

      provider_accounts.zip(accounts).each { |provider_account, account| AccountProvider.create!(account: account, provider: provider_account) }
      [ item, accounts ]
    end
end
