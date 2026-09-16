require "test_helper"
require_relative "../../../support/account_sync_input_test_helper"

class Ingestion::HistoricalBalances::TradeFlowSnapshotTest < ActiveSupport::TestCase
  include AccountSyncInputTestHelper
  self.use_transactional_tests = false

  test "captured exact FX survives serialization and executes inside financial locks without another lookup" do
    with_account_input do
      @account.entries.create!(name: "Foreign trade", date: Date.new(2026, 5, 7), amount: "80", currency: "EUR",
        entryable: Trade.new(qty: 1, price: 80, currency: "EUR", security: securities(:aapl)))
      resolver = mock("capture one exact rate")
      resolver.expects(:call).once.with(from: "EUR", to: "CHF", date: Date.new(2026, 5, 7)).returns(rate: BigDecimal("1.25"), date: "2026-05-06")
      captured = Ingestion::HistoricalBalances::TradeFlowSnapshot.capture(account: @account, rate_resolver: resolver)
      restored = Ingestion::HistoricalBalances::TradeFlowSnapshot.load(JSON.parse(JSON.generate(captured.payload)))
      @account.with_lock do
        data = restored.resolve(inputs: Ingestion::HistoricalBalances::Inputs.capture(@account), currency: "CHF")
        assert_equal BigDecimal("100"), data.fetch(:flows).fetch(Date.new(2026, 5, 7))
        assert_equal Date.new(2026, 5, 6), data.fetch(:evidence).sole.fetch("rate_date")
        plan = Ingestion::HistoricalBalances::IbkrPlan.new(**@handoff.resolve(account: @account, provider_sync: @provider_sync),
          trade_flow_snapshot: restored, rate_resolver: resolver)
        assert_equal BigDecimal("100"), plan.prepare(phase: "equity_history")[:rows].first[:non_cash_adjustments]
      end
    end
  end
end
