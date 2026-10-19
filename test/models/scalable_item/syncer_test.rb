require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItem::SyncerTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    Account.any_instance.stubs(:sync_later).returns(nil)
    @item = scalable_connected_item
    ScalableItem::HistoryReader.any_instance.stubs(:read).returns([])
  end

  test "reads every discovered broker portfolio using the separate verified account ID" do
    now = Time.current
    person_id = @item.person_identity
    account_id = "distinct-broker-account"
    portfolio_ids = %w[portfolio-one portfolio-two]
    discovery = { "account" => { "id" => account_id, "brokerPortfolios" => portfolio_ids.map { |id| { "id" => id } } } }
    provider = mock("scalable provider")
    provider.stubs(:person_identity).returns(person_id)
    provider.expects(:read).with(:broker_portfolios, variables: { "id" => person_id }).returns(discovery)

    portfolio_ids.each do |portfolio_id|
      variables = { "accountId" => account_id, "portfolioId" => portfolio_id }
      provider.expects(:read).with(:broker_overview, variables: variables.merge("includeYearToDate" => false))
        .returns(overview_response(account_id, portfolio_id, now))
      provider.expects(:read).with(:broker_cash_breakdown, variables: variables)
        .twice.returns(cash_response(account_id, portfolio_id))
      provider.expects(:read).with(:broker_holdings,
        variables: variables.merge("includeYearToDate" => false, "quoteSource" => nil))
        .returns(holdings_response(account_id, portfolio_id))
    end
    @item.stubs(:with_authenticated_provider).yields(provider)

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal portfolio_ids, @item.scalable_accounts.order(:uid).pluck(:uid)
    assert_equal 2, @item.accounts.distinct.count
  end

  test "does no provider reads during a saved cooldown" do
    @item.update!(next_sync_at: 5.minutes.from_now)
    @item.expects(:with_authenticated_provider).never

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal 0, @item.scalable_accounts.count
  end

  test "cash history imports once and reconstructs the balance before today's deposit" do
    provider = stub("scalable provider", person_identity: @item.person_identity)
    account_id = "broker-account"
    portfolio_id = "broker-portfolio"
    provider.stubs(:read).with(:broker_portfolios, variables: { "id" => @item.person_identity })
      .returns({ "account" => { "id" => account_id, "brokerPortfolios" => [ { "id" => portfolio_id } ] } })
    variables = { "accountId" => account_id, "portfolioId" => portfolio_id }
    provider.stubs(:read).with(:broker_overview, variables: variables.merge("includeYearToDate" => false))
      .returns(overview_response(account_id, portfolio_id, Time.current, amount: "51"))
    provider.stubs(:read).with(:broker_cash_breakdown, variables: variables)
      .returns(cash_response(account_id, portfolio_id, amount: "51"))
    provider.stubs(:read).with(:broker_holdings, variables: variables.merge("includeYearToDate" => false, "quoteSource" => nil))
      .returns(holdings_response(account_id, portfolio_id))
    @item.stubs(:with_authenticated_provider).yields(provider)
    ScalableItem::HistoryReader.any_instance.stubs(:read).returns(cash_history)

    2.times do
      @item.update!(next_sync_at: nil)
      ScalableItem::Syncer.new(@item).perform_sync(nil)
    end

    account = @item.reload.accounts.sole
    assert_equal 4, account.entries.where(source: "scalable", entryable_type: "Transaction").count
    assert_equal [ "funds_movement" ], account.entries.where(source: "scalable").map { |entry| entry.transaction.kind }.uniq
    assert_equal 51.to_d, account.reload.balance
    assert_equal 51.to_d, account.cash_balance
    assert_nil @item.last_sync_error_code
    assert JSON.parse(@item.scalable_accounts.sole.raw_metadata).fetch("history").present?

    balances = Balance::ReverseCalculator.new(account).calculate.index_by(&:date)
    assert_equal 1.to_d, balances.fetch(Date.current.prev_day).balance
    assert_equal 51.to_d, balances.fetch(Date.current).balance
    assert_equal (Date.current - 100), account.history_start_date
  end

  test "an incomplete history response keeps a successfully refreshed balance" do
    ScalableItem::HistoryReader.any_instance.stubs(:read).raises(Provider::Scalable::Error.new(:history_incomplete))
    discovery = { "account" => { "id" => "account", "brokerPortfolios" => [ { "id" => "portfolio" } ] } }
    provider = stub("scalable provider", person_identity: @item.person_identity)
    provider.stubs(:read).returns(discovery, overview_response("account", "portfolio", Time.current),
      cash_response("account", "portfolio"), holdings_response("account", "portfolio"))
    @item.stubs(:with_authenticated_provider).yields(provider)

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal 25.to_d, @item.reload.accounts.sole.balance
    assert_equal "history_incomplete", @item.last_sync_error_code
    assert @item.session_configured?
    assert_match(/cash history/i, @item.error_message)
  end

  test "refresh rotation inside failed history survives its savepoint rollback" do
    callback = nil
    provider = stub("scalable provider", person_identity: @item.person_identity)
    Provider::Scalable.expects(:new).with do |credentials:, on_credentials_update:|
      callback = on_credentials_update
      credentials.fetch("refresh_token") == "synthetic-refresh"
    end.returns(provider)
    provider.expects(:refresh_if_needed!)
    discovery = { "account" => { "id" => "account", "brokerPortfolios" => [ { "id" => "portfolio" } ] } }
    provider.stubs(:read).returns(discovery, overview_response("account", "portfolio", Time.current),
      cash_response("account", "portfolio"), holdings_response("account", "portfolio"))
    ScalableItem::HistoryReader.any_instance.stubs(:read).with do
      callback.call(scalable_credentials(refresh: "rotated-in-history"))
      true
    end.raises(Provider::Scalable::Error.new(:history_changed))

    ScalableItem::Syncer.new(@item).perform_sync(nil)

    assert_equal "rotated-in-history", @item.reload.credentials_data.fetch("refresh_token")
    assert_equal "history_changed", @item.last_sync_error_code
    assert @item.snapshot_at
    assert_equal 25.to_d, @item.accounts.sole.balance
    assert_empty @item.accounts.sole.entries.where(source: "scalable")
  end

  private

    def overview_response(account_id, portfolio_id, observed_at, amount: "25")
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id,
        "valuation" => { "valuation" => amount, "securitiesValuation" => "0", "cryptoValuation" => "0",
          "timestampUtc" => { "time" => observed_at.iso8601 },
          "lastInventoryUpdateTimestampUtc" => { "time" => observed_at.iso8601 } } } } }
    end

    def cash_response(account_id, portfolio_id, amount: "25")
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id,
        "payments" => { "buyingPower" => { "cashBalance" => amount, "loaned" => "0", "cashAvailableToInvest" => amount } } } } }
    end

    def holdings_response(account_id, portfolio_id)
      { "account" => { "id" => account_id, "brokerPortfolio" => { "id" => portfolio_id, "inventory" => { "items" => [] } } } }
    end

    def cash_history
      [ [ "first", Date.current - 100, "DEPOSIT", "1" ],
        [ "second", Date.current - 30, "DEPOSIT", "1" ],
        [ "withdrawal", Date.current - 28, "WITHDRAWAL", "-1" ],
        [ "latest", Date.current, "DEPOSIT", "50" ] ].map do |id, date, type, amount|
        { "__typename" => "BrokerCashTransaction", "id" => id, "currency" => "EUR",
          "type" => "CASH_TRANSACTION", "cashTransactionType" => type, "amount" => amount,
          "lastEventDateTime" => "#{date.iso8601}T00:00:00.000Z", "isPending" => false,
          "isCancellation" => false, "summary_status" => "SETTLED",
          "cashTransactionHistory" => [ { "state" => "SETTLED" } ] }
      end
    end
end
