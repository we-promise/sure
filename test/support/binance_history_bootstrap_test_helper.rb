require_relative "identity_bootstrap_test_helper"

module BinanceHistoryBootstrapTestHelper
  include IdentityBootstrapTestHelper

  HistoryContext = Data.define(:family, :item, :source, :account, :link, :copier, :control, :mapping, :external)
  HISTORY_TIMESTAMP = Time.utc(2026, 9, 14).to_i * 1000 + 123

  private
    def with_history_copy(linked: true, account_type: "combined")
      with_provider_encryption do
        family = families(:dylan_family)
        item = BinanceItem.create!(family: family, name: "Seed installation", api_key: "private-history-key", api_secret: "private-history-secret")
        account = family.accounts.create!(name: "Retained Binance", currency: "USD", balance: 1000, accountable: Crypto.new)
        begin
          cache = { "spot" => { "BTCUSDT" => [ { "id" => 42, "time" => HISTORY_TIMESTAMP, "qty" => "1", "price" => "10", "quoteQty" => "10", "commission" => "0", "isBuyer" => true } ] },
            "futures" => {}, "p2p" => [ { "orderNumber" => "order-01", "tradeType" => "BUY", "createTime" => HISTORY_TIMESTAMP,
              "fiat" => "USD", "totalPrice" => "10", "unitPrice" => "1", "amount" => "10", "asset" => "USDT" } ] }
          source = item.binance_accounts.create!(name: "Combined", account_type: account_type, currency: "USD", current_balance: 1000,
            raw_payload: { "assets" => [] }, raw_transactions_payload: cache)
          link = AccountProvider.create!(account: account, provider: source) if linked
          ids = linked ? [ "binance_spot_BTCUSDT_42", "binance_p2p_order-01", "binance_p2p_order-01_funding" ] : []
          ids.each do |id|
            entryable = id.end_with?("funding") ? Transaction.new : Trade.new(security: securities(:aapl), qty: 1, price: 10, currency: "USD")
            account.entries.create!(external_id: id, source: "binance", name: "Retained entry", date: Date.current, currency: "USD", amount: 10, entryable: entryable)
          end
          copier = Provider::AccountData::MigrationCopier.new(provider_key: "binance", legacy_item_id: item.id)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", legacy_id: source.id)
          %w[activities balances holdings].each { |resource| Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: resource) } if linked
          yield HistoryContext.new(family: family, item: item, source: source, account: account, link: link&.reload, copier: copier,
            control: control, mapping: mapping, external: mapping.external_account)
        ensure
          cleanup_identity_source(item, account)
        end
      end
    end

end
