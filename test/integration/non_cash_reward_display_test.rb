require "test_helper"

class NonCashRewardDisplayTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @account = accounts(:crypto)
    @kraken = kraken_accounts(:one)
    @kraken.ensure_account_provider!(@account)
    @date = 3.days.ago.to_date
    @security = KrakenAccount::SecurityResolver.resolve("ETH")
    Security.any_instance.stubs(:import_provider_prices)
    @security.prices.create!(date: Date.current, currency: "USD", price: 4_000)
  end

  test "the account list values staking and Earn rewards at receipt with zero cash movement" do
    @security.prices.create!(date: @date, currency: "USD", price: 2_000)
    rewards = [ import_reward("staking"), import_reward("earn", "rewardallocation") ]
    get account_url(@account, tab: "activity")
    assert_response :success
    rewards.each do |entry|
      assert_equal 0, entry.amount
      assert_equal 0.0125.to_d, entry.trade.qty
      assert_reward_row entry, "$25.00"
    end
  end

  test "the drawer shows the historical reward value separately from cash" do
    @security.prices.create!(date: @date, currency: "USD", price: 2_000)
    assert_reward_header import_reward("staking"), "$25.00 USD"
    assert_select "dd", text: /\$25\.00.*100\.0%/m
    assert_select "dt", text: "Cash movement" do |labels|
      assert_equal "$0.00", labels.first.next_element.text.strip
    end
  end

  test "a flagged spot price stays unavailable until a sync finds the historical price" do
    entry = import_reward("earn", "reward")
    assert_equal 4_000, entry.trade.price
    get account_url(@account, tab: "activity")
    assert_reward_row entry, "Unavailable"
    assert_reward_header entry, "Unavailable"
    assert_select "dt", text: "Unit price at receipt" do |labels|
      assert_equal "Unavailable", labels.first.next_element.text.strip
    end
    assert_select "dt", text: "Unrealized gain/loss", count: 0

    @security.prices.create!(date: @date, currency: "USD", price: 1_000)
    assert_no_difference -> { @account.entries.count } do
      KrakenAccount::LedgerProcessor.new(@kraken).process
    end
    assert_reward_header entry, "$12.50 USD"
    assert_equal 0, entry.reload.amount
  end

  test "a small priced reward shows a fraction of the minor unit in the trade currency" do
    @security.prices.create!(date: @date, currency: "USD", price: 0.1)
    entry = import_reward("staking")
    entry.trade.update!(currency: "EUR")
    get account_url(@account, tab: "activity")
    assert_reward_row entry, "< €0.01"
    assert_reward_header entry, "< €0.01 EUR"
    assert_select "dt", text: "Unrealized gain/loss", count: 0
  end

  test "another provider can use both reward views with its own metadata" do
    entry = entries(:trade)
    entry.update!(source: "example", amount: 0)
    entry.trade.update!(qty: 0.125, price: 200, extra: { "example" => { "activity" => "bonus" } })

    provider = stub("reward provider")
    provider.stubs(:reward_price_status).with({ "activity" => "bonus" }).returns(:historical)
    stub_const(Trade, :REWARD_PROVIDERS, { "example" => provider }) do
      get account_url(entry.account, tab: "activity")
      assert_response :success
      assert_reward_row entry, "$25.00"
      assert_reward_header entry, "$25.00 USD"
    end
  end

  test "ordinary trades and cash dividends keep their cash amounts in the list and drawer" do
    entry = entries(:trade)
    [
      [ "Buy", 2, 35, "-$35.00", "$35.00" ],
      [ "Sell", -2, -35, "$35.00", "-$35.00" ],
      [ "Transfer", 2, 0, "$0.00", "$0.00" ],
      [ "Dividend", 0, -5, "$5.00", "$5.00" ]
    ].each do |label, qty, amount, row_value, header_value|
      entry.update!(amount: amount)
      entry.trade.update!(investment_activity_label: label, qty: qty)

      get account_url(entry.account, tab: "activity")
      assert_response :success
      assert_select "##{dom_id(entry.trade)} p.privacy-sensitive", text: row_value

      get trade_url(entry)
      assert_response :success
      assert_select "header h3 .privacy-sensitive", text: header_value
      assert_select "header h3 span", text: "Estimated value received (non-cash)", count: 0
    end
  end

  private
    def import_reward(type, subtype = "")
      @kraken.update!(
        raw_payload: { assets: [ { symbol: "ETH", price_usd: "4000" } ] },
        raw_transactions_payload: { ledgers: {
          type => { type: type, subtype: subtype, asset: "ETH", amount: "0.013", fee: "0.0005", time: @date.in_time_zone.to_i }
        } }
      )
      KrakenAccount::LedgerProcessor.new(@kraken).process
      @account.entries.find_by!(external_id: "kraken_ledger_#{type}")
    end

    def assert_reward_row(entry, value)
      assert_select "##{dom_id(entry.trade)}" do
        assert_select ".privacy-sensitive", text: value
        assert_select "span", text: "Non-cash estimate"
      end
    end

    def assert_reward_header(entry, value)
      get trade_url(entry)
      assert_response :success
      assert_select "header h3" do
        assert_select ".privacy-sensitive", text: value
        assert_select "span", text: "Estimated value received (non-cash)"
      end
    end
end
