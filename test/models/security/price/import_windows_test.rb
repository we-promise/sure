require "test_helper"

class Security::Price::ImportWindowsTest < ActiveSupport::TestCase
  setup do
    Security::Price.delete_all
    Trade.delete_all
    Holding.delete_all
    Security.delete_all
  end

  test "uses the last positive holding for a closed position without trades" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "HIST", exchange_operating_mic: "XNAS")
    held_date = 10.days.ago.to_date

    account.holdings.create!(security: security, date: held_date, qty: 2, price: 100, amount: 200, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 100, amount: 0, currency: "USD")

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal held_date, window.start_date
    assert_equal held_date, window.end_date
  end

  test "recognizes a new manual buy before holdings are rematerialized" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "REOPEN", exchange_operating_mic: "XNAS")
    buy_date = 20.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    account.entries.create!(name: "Sell", date: 10.days.ago.to_date, amount: 110, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 110, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")

    account.entries.create!(name: "Rebuy", date: 2.days.ago.to_date, amount: 120, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 120, currency: "USD", investment_activity_label: "Buy"))

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal buy_date, window.start_date
    assert_equal Date.current, window.end_date
  end

  test "a materialized zero holding closes a position even when raw trade quantities are positive" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "SPLIT", exchange_operating_mic: "XNAS")
    buy_date = 30.days.ago.to_date
    sell_date = 5.days.ago.to_date

    account.entries.create!(name: "Buy", date: buy_date, amount: 1000, currency: "USD",
                            entryable: Trade.new(security: security, qty: 10, price: 100, currency: "USD", investment_activity_label: "Buy"))
    # A 1-for-10 reverse split leaves one share to sell. The split is reflected
    # in the materialized holdings, not in the original trade quantities.
    account.entries.create!(name: "Sell", date: sell_date, amount: 100, currency: "USD",
                            entryable: Trade.new(security: security, qty: -1, price: 100, currency: "USD", investment_activity_label: "Sell"))
    account.holdings.create!(security: security, date: sell_date - 1.day, qty: 1, price: 100, amount: 100, currency: "USD")
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 100, amount: 0, currency: "USD")

    assert_equal 9, account.trades.sum(:qty)
    assert_equal sell_date, Security::Price::ImportWindows.new(account).to_h.fetch(security.id).end_date
  end

  test "recognizes a buy after a closed provider snapshot" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "LINKED", exchange_operating_mic: "XNAS")
    provider_item = family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider_account = provider_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = AccountProvider.create!(account: account, provider: provider_account)
    first_held_date = 20.days.ago.to_date
    sold_date = 10.days.ago.to_date

    account.holdings.create!(security: security, date: first_held_date, qty: 1, price: 100, amount: 100,
                             currency: "USD", account_provider: account_provider)
    account.holdings.create!(security: security, date: sold_date, qty: 0, price: 110, amount: 0,
                             currency: "USD", account_provider: account_provider)
    account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")

    account.entries.create!(name: "Buy", date: 2.days.ago.to_date, amount: 120, currency: "USD",
                            entryable: Trade.new(security: security, qty: 1, price: 120, currency: "USD", investment_activity_label: "Buy"))

    window = Security::Price::ImportWindows.new(account).to_h.fetch(security.id)

    assert_equal first_held_date, window.start_date
    assert_equal Date.current, window.end_date
  end
  # Editing the closing trade reopens the position before holdings are
  # rebuilt. The edit changes no buy, so only the trade's own update time shows it.
  test "an edited closing trade reopens the position before holdings are rematerialized" do
    account, security = closed_manual_position("EDITED")
    sell = account.trades.find_by!(security: security, qty: -10)

    travel 1.second do
      sell.update!(qty: -5)
      assert_equal Date.current, Security::Price::ImportWindows.new(account).to_h.fetch(security.id).end_date
    end
  end

  # A short sale after a closed position: net quantity negative, so a check for
  # a net-positive (long) reopen alone never fires.
  test "a short sale after a closed position reopens it before rematerialization" do
    account, security = closed_manual_position("SHORTED")

    travel 1.second do
      account.entries.create!(name: "Short", date: 2.days.ago.to_date, amount: -500, currency: "USD",
                              entryable: Trade.new(security: security, qty: -5, price: 100, currency: "USD", investment_activity_label: "Sell"))
      assert_equal Date.current, Security::Price::ImportWindows.new(account).to_h.fetch(security.id).end_date
    end
  end

  # trades.qty is nullable in the schema even though Trade validates it; a
  # legacy NULL must not abort the window for every other security.
  test "a trade with no quantity does not abort the windows" do
    family = Family.create!(name: "Smith", currency: "USD")
    account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
    security = Security.create!(ticker: "NULLQTY", exchange_operating_mic: "XNAS")
    entry = account.entries.create!(name: "Buy", date: 10.days.ago.to_date, amount: 100, currency: "USD",
                                    entryable: Trade.new(security: security, qty: 1, price: 100, currency: "USD", investment_activity_label: "Buy"))
    entry.entryable.update_column(:qty, nil)

    assert_nothing_raised { Security::Price::ImportWindows.new(account).to_h }
  end

  private
    # Bought 10, sold 10, and holdings already rebuilt to zero through today.
    def closed_manual_position(ticker)
      family = Family.create!(name: "Smith", currency: "USD")
      account = family.accounts.create!(name: "Brokerage", currency: "USD", balance: 0, accountable: Investment.new)
      security = Security.create!(ticker: ticker, exchange_operating_mic: "XNAS")
      account.entries.create!(name: "Buy", date: 20.days.ago.to_date, amount: 1000, currency: "USD",
                              entryable: Trade.new(security: security, qty: 10, price: 100, currency: "USD", investment_activity_label: "Buy"))
      account.entries.create!(name: "Sell", date: 10.days.ago.to_date, amount: -1100, currency: "USD",
                              entryable: Trade.new(security: security, qty: -10, price: 110, currency: "USD", investment_activity_label: "Sell"))
      account.holdings.create!(security: security, date: 15.days.ago.to_date, qty: 10, price: 105, amount: 1050, currency: "USD")
      account.holdings.create!(security: security, date: Date.current, qty: 0, price: 110, amount: 0, currency: "USD")
      [ account, security ]
    end
end
