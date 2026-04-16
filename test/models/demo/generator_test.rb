require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  setup do
    @generator = Demo::Generator.new(seed: 123)
  end

  test "create_transfer! marks credit card payments as transfer kinds" do
    transfer = nil

    assert_difference "Transfer.count", 1 do
      transfer = @generator.send(
        :create_transfer!,
        accounts(:depository),
        accounts(:credit_card),
        250,
        "Amex Payment",
        Date.current
      )
    end

    assert_equal "cc_payment", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind
    assert transfer.outflow_transaction.transfer?
    assert transfer.inflow_transaction.transfer?
    assert_equal "confirmed", transfer.status
  end

  test "create_transfer! marks contributions to investment accounts" do
    family = accounts(:depository).family
    expected_category = ensure_investment_contributions_category(family)
    transfer = nil

    assert_difference "Transfer.count", 1 do
      transfer = @generator.send(
        :create_transfer!,
        accounts(:depository),
        accounts(:investment),
        500,
        "HSA Contribution",
        Date.current
      )
    end

    assert_equal "investment_contribution", transfer.outflow_transaction.kind
    assert_equal expected_category.id, transfer.outflow_transaction.category_id
    assert_equal "funds_movement", transfer.inflow_transaction.kind
  end

  test "create_transfer! keeps investment rollovers as funds movement" do
    transfer = nil

    assert_difference "Transfer.count", 1 do
      transfer = @generator.send(
        :create_transfer!,
        accounts(:investment),
        accounts(:crypto),
        300,
        "Rollover",
        Date.current
      )
    end

    assert_equal "funds_movement", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind
  end
end
