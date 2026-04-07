require "test_helper"

class EnableBankingItem::ImporterBalanceSelectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test Enable Banking",
      country_code: "AT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )

    mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: mock_provider)
  end

  test "prefers CLBD when multiple balance types are present" do
    balances = [
      { balance_type: "ITAV", balance_amount: { amount: "4332.81", currency: "EUR" } },
      { balance_type: "CLAV", balance_amount: { amount: "4332.81", currency: "EUR" } },
      { balance_type: "ITBD", balance_amount: { amount: "232.81", currency: "EUR" } },
      { balance_type: "CLBD", balance_amount: { amount: "232.81", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "CLBD", result[:balance_type]
    assert_equal "232.81", result[:balance_amount][:amount]
  end

  test "prefers XPCD over ITBD" do
    balances = [
      { balance_type: "ITBD", balance_amount: { amount: "100.00", currency: "EUR" } },
      { balance_type: "XPCD", balance_amount: { amount: "150.00", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "XPCD", result[:balance_type]
  end

  test "falls back through priority chain" do
    balances = [
      { balance_type: "ITAV", balance_amount: { amount: "5000.00", currency: "EUR" } },
      { balance_type: "ITBD", balance_amount: { amount: "900.00", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "ITBD", result[:balance_type]
  end

  test "CLAV is preferred over ITAV" do
    balances = [
      { balance_type: "ITAV", balance_amount: { amount: "5000.00", currency: "EUR" } },
      { balance_type: "CLAV", balance_amount: { amount: "4800.00", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "CLAV", result[:balance_type]
  end

  test "falls back to first balance when no known types present" do
    balances = [
      { balance_type: "PRCD", balance_amount: { amount: "500.00", currency: "EUR" } },
      { balance_type: "INFO", balance_amount: { amount: "600.00", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "PRCD", result[:balance_type]
    assert_equal "500.00", result[:balance_amount][:amount]
  end

  test "returns single balance regardless of type" do
    balances = [
      { balance_type: "ITAV", balance_amount: { amount: "1000.00", currency: "EUR" } }
    ]

    result = @importer.send(:select_balance, balances)

    assert_equal "ITAV", result[:balance_type]
  end
end
