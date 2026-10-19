require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class Holding::ScalableSnapshotCalculatorTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    item = scalable_connected_item
    @provider_account = item.scalable_accounts.create!(uid: "synthetic-portfolio", name: "Scalable Broker",
      currency: "EUR", kind: "broker", current_balance: 70, cash_balance: 50)
    @provider_account.ensure_account_provider!(allow_bootstrap: true)
    @account = @provider_account.usable_account
    @link = @provider_account.account_provider
    @security = Security.create!(ticker: "IE00B4L5Y983", name: "Synthetic fund", offline: true)
  end

  test "carries observed valuations forward without reconstructing older holdings or cost basis" do
    date = 2.days.ago.to_date
    @account.holdings.create!(security: @security, account_provider: @link, external_id: "synthetic-holding",
      date: date, qty: 2, amount: 20, price: 10, currency: "EUR")

    rows = Holding::ScalableSnapshotCalculator.new(@account).calculate
    assert_equal date..Date.current, rows.map(&:date).min..rows.map(&:date).max
    assert rows.all? { |row| row.qty == 2 && row.amount == 20 && row.price == 10 }
    assert rows.all? { |row| row.cost_basis.nil? && row.cost_basis_unknown }
    refute rows.any? { |row| row.date < date }
  end

  test "zero snapshots stop a sold holding from returning on later days" do
    @account.holdings.create!(security: @security, account_provider: @link, external_id: "synthetic-before",
      date: 3.days.ago.to_date, qty: 2, amount: 20, price: 10, currency: "EUR")
    @account.holdings.create!(security: @security, account_provider: @link, external_id: "synthetic-sold",
      date: 1.day.ago.to_date, qty: 0, amount: 0, price: 10, currency: "EUR")

    rows = Holding::ScalableSnapshotCalculator.new(@account).calculate
    assert rows.select { |row| row.date >= 1.day.ago.to_date }.all? { |row| row.qty.zero? && row.amount.zero? }
    assert_equal 0, rows.find { |row| row.date == Date.current }.qty
  end

  test "partial local history cannot invent a cost basis for the bank snapshot" do
    holding = @account.holdings.create!(security: @security, account_provider: @link, external_id: "synthetic-holding",
      date: Date.current, qty: 2, amount: 20, price: 10, currency: "EUR")
    holding.expects(:calculate_avg_cost).never
    assert_nil holding.avg_cost
    holding.update!(cost_basis: 3, cost_basis_source: "calculated")
    assert_nil holding.avg_cost
    holding.update!(cost_basis: 3, cost_basis_source: "manual", cost_basis_locked: true)
    assert_equal Money.new(3, "EUR"), holding.avg_cost
  end
end
