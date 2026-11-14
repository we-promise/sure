require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetHoldings.new(@user)
    @account = accounts(:investment)
    # The fixtures hold only AAPL, so a second ticker on the same account is
    # what tells a filter from no filter.
    @account.holdings.create!(security: securities(:msft), date: Date.current, qty: 3, price: 400, amount: 1200, currency: "USD")
  end

  test "get_holdings filters by security ticker" do
    assert_equal [ "AAPL" ], tickers("securities" => [ "AAPL" ])
    assert_equal [ "MSFT" ], tickers("securities" => [ "MSFT" ])
    assert_equal 1, @fn.call("page" => 1, "securities" => [ "MSFT" ])[:total_results]
  end

  test "get_holdings security filter for a ticker nobody holds returns nothing" do
    assert_empty tickers("securities" => [ "NOPE" ])
  end

  test "get_holdings security filter does not reach another user's private account" do
    private_account = @user.family.accounts.create!(name: "Member Brokerage", accountable: Investment.new, balance: 0, currency: "USD", owner: users(:family_member))
    hidden = private_account.holdings.create!(security: securities(:aapl), date: Date.current, qty: 9, price: 200, amount: 1800, currency: "USD")

    rows = @fn.call("page" => 1, "securities" => [ "AAPL" ])[:holdings]

    assert_includes rows.map { |row| row[:account] }, @account.name, "the user's own AAPL went too"
    assert_not_includes rows.map { |row| row[:account] }, hidden.account.name
  end

  test "get_holdings without a security filter is unchanged" do
    assert_equal [ "AAPL", "MSFT" ], tickers({})
  end

  # A provider sync lists what the account holds now. A position sold
  # between two days' syncs keeps its last row from the earlier day; the
  # assistant must not list it, just as the holdings page does not.
  test "get_holdings leaves out a position sold since the latest provider snapshot" do
    account = @user.family.accounts.create!(name: "Linked brokerage", balance: 3000, cash_balance: 1500, currency: "USD", accountable: Investment.new, owner: @user)
    snaptrade_account = snaptrade_accounts(:fidelity_401k)
    snaptrade_account.ensure_account_provider!(account)

    sync_snaptrade_positions!(snaptrade_account, %w[AAPL MSFT], on: Date.new(2026, 12, 17))
    sync_snaptrade_positions!(snaptrade_account, %w[AAPL], on: Date.new(2026, 12, 18))

    assert_equal %w[AAPL], account.reload.current_holdings.map { |h| h.security.ticker }
    rows = Assistant::Function::GetHoldings.new(@user).call("page" => 1, "accounts" => [ account.name ])[:holdings]
    assert_equal %w[AAPL], rows.map { |row| row[:ticker] }
  end

  private
    def sync_snaptrade_positions!(snaptrade_account, tickers, on:)
      travel_to(on) do
        positions = tickers.map do |ticker|
          { "instrument" => { "kind" => "stock", "symbol" => ticker }, "units" => "10", "price" => "150.00", "currency" => "USD" }
        end
        snaptrade_account.update!(currency: "USD", cash_balance: 1500, current_balance: 1500 + 1500 * tickers.size,
          last_holdings_sync: Time.current, raw_holdings_payload: positions, raw_activities_payload: [])
        SnaptradeAccount::Processor.new(snaptrade_account.reload).process
      end
    end

    def tickers(params)
      @fn.call({ "page" => 1 }.merge(params))[:holdings].map { |row| row[:ticker] }.uniq.sort
    end
end
