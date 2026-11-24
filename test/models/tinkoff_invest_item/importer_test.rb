require "test_helper"

class TinkoffInvestItem::ImporterTest < ActiveSupport::TestCase
  class FakeProvider
    attr_reader :calls

    def initialize(accounts:, portfolios: {}, operations: {}, instruments: {}, error: nil)
      @accounts = accounts
      @portfolios = portfolios
      @operations = operations
      @instruments = instruments
      @error = error
      @calls = []
    end

    def fetch_accounts
      raise @error if @error

      @calls << [ :accounts ]
      @accounts
    end

    def fetch_portfolio(account_id, currency: "RUB")
      @calls << [ :portfolio, account_id, currency ]
      @portfolios.fetch(account_id, {})
    end

    def fetch_operations(account_id, cursor: nil, from: nil, to: nil)
      @calls << [ :operations, account_id, from, cursor ]
      @operations.fetch(account_id, { items: [], next_cursor: nil })
    end

    def resolve_instrument(instrument_uid: nil, figi: nil, ticker_hint: nil, **)
      @instruments[instrument_uid] || @instruments[figi] || @instruments[ticker_hint]
    end
  end

  ACCOUNTS = [
    {
      "id" => "acct-broker-01",
      "type" => "ACCOUNT_TYPE_TINKOFF",
      "name" => "Main Brokerage",
      "status" => "ACCOUNT_STATUS_OPEN",
      "openedDate" => "2021-03-15T00:00:00Z",
      "accessLevel" => "ACCOUNT_ACCESS_LEVEL_READ_ONLY"
    },
    {
      "id" => "acct-box-03",
      "type" => "ACCOUNT_TYPE_INVEST_BOX",
      "name" => "Invest Box",
      "status" => "ACCOUNT_STATUS_OPEN",
      "openedDate" => "2024-06-01T00:00:00Z",
      "accessLevel" => "ACCOUNT_ACCESS_LEVEL_READ_ONLY"
    },
    {
      "id" => "acct-closed-99",
      "type" => "ACCOUNT_TYPE_TINKOFF",
      "name" => "Closed Account",
      "status" => "ACCOUNT_STATUS_CLOSED",
      "accessLevel" => "ACCOUNT_ACCESS_LEVEL_READ_ONLY"
    }
  ].freeze

  PORTFOLIO = {
    "totalAmountPortfolio" => { "currency" => "rub", "units" => "1600000", "nano" => 0 },
    "totalAmountCurrencies" => { "currency" => "rub", "units" => "116100", "nano" => 0 },
    "positions" => [
      {
        "figi" => "BBG004730N88",
        "instrumentUid" => "uid-sber",
        "instrumentType" => "share",
        "quantity" => { "units" => "5000", "nano" => 0 },
        "currentPrice" => { "currency" => "rub", "units" => "260", "nano" => 0 }
      },
      {
        "figi" => "RUB000UTSTOM",
        "instrumentUid" => "uid-rub",
        "instrumentType" => "currency",
        "ticker" => "RUB",
        "quantity" => { "units" => "116100", "nano" => 0 }
      }
    ]
  }.freeze

  SBER_META = Provider::TinkoffInvest::PortfolioClient::InstrumentMeta.new(
    uid: "uid-sber",
    figi: "BBG004730N88",
    ticker: "SBER",
    name: "Sberbank",
    instrument_type: "share",
    currency: "RUB",
    exchange_operating_mic: "MISX",
    country_code: "RU",
    nominal: nil,
    initial_nominal: nil,
    amortization_flag: false,
    logo_url: "https://invest-brands.cdn-tinkoff.ru/SBERx160.png"
  )

  setup do
    @family = families(:dylan_family)
    @item = @family.tinkoff_invest_items.create!(name: "T-Invest", api_key: "test-token")
  end

  test "imports open accounts and enriches non-currency positions while skipping closed accounts" do
    provider = FakeProvider.new(
      accounts: ACCOUNTS,
      portfolios: { "acct-broker-01" => PORTFOLIO },
      instruments: { "uid-sber" => SBER_META }
    )

    TinkoffInvestItem::Importer.new(@item, provider: provider).import

    assert_equal 2, @item.tinkoff_invest_accounts.count
    assert_nil @item.tinkoff_invest_accounts.find_by(tinkoff_invest_account_id: "acct-closed-99")

    broker = @item.tinkoff_invest_accounts.find_by!(tinkoff_invest_account_id: "acct-broker-01")
    assert_equal [ "Main Brokerage", "RUB", BigDecimal("1600000"), BigDecimal("116100"), "brokerage" ],
                 [ broker.name, broker.currency, broker.current_balance, broker.cash_balance, broker.accountable_subtype ]
    assert_equal "SBER", broker.raw_portfolio_payload.dig("positions", 0, "resolved_instrument", "ticker")

    box = @item.tinkoff_invest_accounts.find_by!(tinkoff_invest_account_id: "acct-box-03")
    assert_equal "other", box.accountable_subtype
    assert_empty provider.calls.select { |c| c.first == :operations }
  end

  test "fetches operations for linked accounts, persists cursor, and uses lookback overlap on subsequent syncs" do
    tinkoff_acct = @item.tinkoff_invest_accounts.create!(
      name: "Main Brokerage",
      tinkoff_invest_account_id: "acct-broker-01",
      currency: "RUB"
    )
    account = @family.accounts.create!(name: "Main Brokerage", balance: 0, currency: "RUB", accountable: Investment.new)
    tinkoff_acct.ensure_account_provider!(account)

    ops = {
      items: [ { "id" => "op-1", "date" => "2024-02-12T11:15:00Z", "type" => "OPERATION_TYPE_BUY", "instrumentUid" => "uid-sber" } ],
      next_cursor: "cursor-v1"
    }
    provider = FakeProvider.new(
      accounts: ACCOUNTS,
      portfolios: { "acct-broker-01" => PORTFOLIO },
      operations: { "acct-broker-01" => ops },
      instruments: { "uid-sber" => SBER_META }
    )

    travel_to Time.utc(2026, 6, 15, 12, 0, 0) do
      TinkoffInvestItem::Importer.new(@item, provider: provider).import
    end

    tinkoff_acct.reload
    assert_equal "cursor-v1", tinkoff_acct.operations_cursor
    assert_equal Time.utc(2026, 6, 15, 12, 0, 0), tinkoff_acct.last_synced_at
    assert_equal "SBER", tinkoff_acct.raw_operations_payload.dig(0, "resolved_instrument", "ticker")

    initial_op_call = provider.calls.find { |c| c.first == :operations }
    assert_equal Time.utc(2021, 3, 15, 0, 0, 0), initial_op_call[2]

    # Second sync uses a 7-day lookback overlap from last_synced_at
    provider2 = FakeProvider.new(
      accounts: ACCOUNTS,
      portfolios: { "acct-broker-01" => PORTFOLIO },
      operations: { "acct-broker-01" => { items: [], next_cursor: nil } },
      instruments: { "uid-sber" => SBER_META }
    )
    travel_to Time.utc(2026, 6, 20, 12, 0, 0) do
      TinkoffInvestItem::Importer.new(@item, provider: provider2).import
    end

    incremental_op_call = provider2.calls.find { |c| c.first == :operations }
    assert_equal Time.utc(2026, 6, 8, 12, 0, 0), incremental_op_call[2]
    assert_equal "cursor-v1", tinkoff_acct.reload.operations_cursor
  end

  test "removes unlinked accounts missing from GetAccounts and keeps linked ones" do
    stale = @item.tinkoff_invest_accounts.create!(name: "Old", currency: "RUB", tinkoff_invest_account_id: "acct-gone-1")
    linked = @item.tinkoff_invest_accounts.create!(name: "Kept", currency: "RUB", tinkoff_invest_account_id: "acct-gone-2")
    account = @family.accounts.create!(name: "Kept", balance: 0, currency: "RUB", accountable: Investment.new)
    linked.ensure_account_provider!(account)

    provider = FakeProvider.new(accounts: ACCOUNTS, portfolios: {}, instruments: {})
    TinkoffInvestItem::Importer.new(@item, provider: provider).import

    assert_not TinkoffInvestAccount.exists?(stale.id)
    assert TinkoffInvestAccount.exists?(linked.id)
  end

  test "marks item requires_update on AuthenticationError" do
    provider = FakeProvider.new(
      accounts: [],
      error: Provider::TinkoffInvest::PortfolioClient::AuthenticationError.new("invalid token")
    )

    assert_raises(Provider::TinkoffInvest::PortfolioClient::AuthenticationError) do
      TinkoffInvestItem::Importer.new(@item, provider: provider).import
    end

    assert @item.reload.requires_update?
  end
end
