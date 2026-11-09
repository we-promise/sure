require "test_helper"

class MonarchImport::BalanceHistoryTest < ActiveSupport::TestCase
  test "adds no valuation where transactions explain the change" do
    history = history_for("2024-01-01" => 100, "2024-01-02" => 90)

    assert_equal [ [ day("2024-01-01"), 100 ] ], anchors(history: history, flows: amounts("2024-01-02" => -10))
  end

  test "adds a valuation where the balance drifts from the transactions" do
    history = history_for("2024-01-01" => 100, "2024-01-02" => 95)

    assert_equal [ [ day("2024-01-01"), 100 ], [ day("2024-01-02"), 95 ] ],
      anchors(history: history, flows: amounts("2024-01-02" => -10))
  end

  test "opens before transactions that predate the balance history" do
    history = history_for("2024-01-03" => 50)

    assert_equal [ [ day("2023-12-31"), 55 ] ],
      anchors(history: history, flows: amounts("2024-01-01" => -10, "2024-01-02" => 5))
  end

  test "a closed account drops to zero the day after its last balance" do
    assert_equal [ [ day("2024-01-01"), 100 ], [ day("2024-01-02"), 0 ] ],
      anchors(history: history_for("2024-01-01" => 100), closed: true)
  end

  test "replay reproduces every day of the history" do
    history = history_for("2024-01-01" => 100, "2024-01-02" => 90, "2024-01-03" => 93, "2024-01-05" => 80)
    flows = amounts("2024-01-02" => -10, "2024-01-03" => 4, "2024-01-04" => -13)
    balance_history = MonarchImport::BalanceHistory.new(history: history, flows: flows)

    replayed = balance_history.replay(through: day("2024-01-05"))
    history.each { |date, balance| assert_equal balance, replayed[date], date }
  end

  test "a current balance adds a valuation only when it differs" do
    balance_history = MonarchImport::BalanceHistory.new(history: history_for("2024-01-01" => 100))

    assert_equal balance_history.anchors, balance_history.anchors_with_current_balance(day("2024-01-10"), 100)
    assert_equal [ [ day("2024-01-01"), 100 ], [ day("2024-01-10"), 120 ] ],
      balance_history.anchors_with_current_balance(day("2024-01-10"), 120)
  end

  test "existing transactions count toward the balance" do
    history = history_for("2024-01-01" => 100, "2024-01-02" => 90)
    balance_history = MonarchImport::BalanceHistory.new(history: history, existing_flows: amounts("2024-01-02" => -10))

    assert_equal [ [ day("2024-01-01"), 100 ] ], balance_history.anchors
    assert_equal 90, balance_history.replay[day("2024-01-02")]
  end

  test "existing valuations are kept and disagreements are conflicts" do
    history = history_for("2024-01-01" => 100, "2024-01-02" => 90, "2024-01-03" => 90)
    balance_history = MonarchImport::BalanceHistory.new(history: history, existing_valuations: amounts("2024-01-02" => 70))

    assert_equal [ [ day("2024-01-01"), 100 ], [ day("2024-01-03"), 90 ] ], balance_history.anchors
    assert_equal [ day("2024-01-02") ], balance_history.conflicts
  end

  private
    def day(value)
      Date.iso8601(value)
    end

    def amounts(values)
      values.to_h { |date, amount| [ day(date), BigDecimal(amount.to_s) ] }
    end
    alias_method :history_for, :amounts

    def anchors(**options)
      MonarchImport::BalanceHistory.new(**options).anchors.map { |date, balance| [ date, balance.to_i ] }
    end
end
