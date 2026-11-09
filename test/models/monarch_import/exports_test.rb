require "test_helper"

class MonarchImport::ExportsTest < ActiveSupport::TestCase
  setup do
    @exports = MonarchImport::Exports.new(
      balances_csv: file_fixture("imports/monarch_balances.csv").read,
      transactions_csv: file_fixture("imports/monarch_transactions.csv").read
    )
  end

  test "suggests types from the balances and counts every transaction" do
    suggestions = @exports.suggestions.index_by(&:name)

    assert_equal({ "Checking" => "Depository", "Card" => "CreditCard", "Old Savings" => "Investment" },
      suggestions.transform_values(&:type))
    assert_equal 4, suggestions["Checking"].transactions_count
  end

  test "lists the most recently active accounts first" do
    assert_equal "Old Savings", @exports.suggestions.last.name
  end

  test "only suggests long-inactive accounts as closed" do
    balances = "Date,Balance,Account\n2023-01-01,5.00,Old\n2024-12-30,5.00,Recent\n"
    suggestions = MonarchImport::Exports.new(balances_csv: balances).suggestions.index_by(&:name)

    assert suggestions["Old"].closed
    assert_not suggestions["Recent"].closed
  end

  test "pending transactions are left out unless asked for" do
    assert_equal 4, @exports.transactions_for(include_pending: false).size
    assert_equal 5, @exports.transactions_for(include_pending: true).size
  end

  test "without a transactions export it is balances only" do
    exports = MonarchImport::Exports.new(balances_csv: file_fixture("imports/monarch_balances.csv").read)

    assert exports.balances_only?
    assert_equal %w[Card Checking Old\ Savings], exports.account_names
  end

  test "rejects dates outside the range Sure imports" do
    error = assert_raises(MonarchImport::Exports::Error) do
      MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n9999-12-31,5.00,Checking\n")
    end
    assert_match "9999-12-31", error.message
  end

  test "rejects amounts that aren't finite" do
    assert_raises(MonarchImport::Exports::Error) do
      MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n2024-01-01,Infinity,Checking\n")
    end
  end

  test "rejects rows without an account name" do
    error = assert_raises(MonarchImport::Exports::Error) do
      MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n2024-01-01,5.00, \n")
    end
    assert_match "no account name", error.message
  end

  test "rejects exports without any accounts" do
    error = assert_raises(MonarchImport::Exports::Error) do
      MonarchImport::Exports.new(balances_csv: "Date,Balance,Account\n")
    end
    assert_match "don't contain any accounts", error.message
  end

  test "rejects a file that isn't the right export" do
    error = assert_raises(MonarchImport::Exports::Error) do
      MonarchImport::Exports.new(balances_csv: file_fixture("imports/monarch_transactions.csv").read)
    end
    assert_match "Balance", error.message
  end
end
