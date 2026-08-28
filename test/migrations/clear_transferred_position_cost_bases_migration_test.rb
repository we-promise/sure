# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260826090000_clear_transferred_position_cost_bases")

class ClearTransferredPositionCostBasesMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Migration test",
      balance: 2_000,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "clears inbound transfer basis without clearing outbound transfer basis" do
    inbound = create_position(ticker: "MIGRIN", transfer_qty: 2)
    outbound = create_position(ticker: "MIGROUT", transfer_qty: -2)

    migration = ClearTransferredPositionCostBases.new
    migration.suppress_messages { migration.migrate(:up) }

    assert_nil inbound.reload.cost_basis
    assert_nil inbound.cost_basis_source
    assert_equal BigDecimal("100"), outbound.reload.cost_basis
    assert_equal "calculated", outbound.cost_basis_source
  end

  private

    def create_position(ticker:, transfer_qty:)
      security = Security.create!(ticker: ticker, name: ticker)
      purchase_date = 2.days.ago.to_date
      transfer_date = 1.day.ago.to_date

      create_trade(
        security,
        account: @account,
        qty: 10,
        price: 100,
        date: purchase_date
      )
      transfer = create_trade(
        security,
        account: @account,
        qty: transfer_qty,
        price: 150,
        date: transfer_date
      )
      transfer.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)

      qty = 10 + transfer_qty
      @account.holdings.create!(
        security: security,
        date: transfer_date,
        qty: qty,
        price: 150,
        amount: qty * 150,
        currency: "USD",
        cost_basis: 100,
        cost_basis_source: "calculated"
      )
    end
end
