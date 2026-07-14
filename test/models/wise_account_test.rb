require "test_helper"

class WiseAccountTest < ActiveSupport::TestCase
  setup do
    @wise_item = wise_items(:one)
    @checking = wise_accounts(:checking)
    @jar = wise_accounts(:jar)
  end

  # jar?

  test "jar? returns false for STANDARD balance" do
    @checking.update!(raw_payload: { "type" => "STANDARD" })
    assert_not @checking.jar?
  end

  test "jar? returns true for SAVINGS balance" do
    @jar.update!(raw_payload: { "type" => "SAVINGS" })
    assert @jar.jar?
  end

  test "jar? returns false when raw_payload is nil" do
    @checking.update!(raw_payload: nil)
    assert_not @checking.jar?
  end

  # account_subtype

  test "account_subtype returns checking for STANDARD account" do
    @checking.update!(raw_payload: { "type" => "STANDARD" })
    assert_equal "checking", @checking.account_subtype
  end

  test "account_subtype returns savings for JAR account" do
    @jar.update!(raw_payload: { "type" => "SAVINGS" })
    assert_equal "savings", @jar.account_subtype
  end

  # upsert_wise_snapshot!

  test "upsert_wise_snapshot! updates balance from STANDARD response" do
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 2500.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 100.0, "currency" => "EUR" },
      "type" => "STANDARD"
    }

    @checking.upsert_wise_snapshot!(balance_data)

    assert_equal BigDecimal("2500.0"), @checking.current_balance
    assert_equal BigDecimal("100.0"), @checking.reserved_balance
    assert_equal "EUR", @checking.currency
    assert_equal "STANDARD", @checking.raw_payload["type"]
  end

  test "upsert_wise_snapshot! uses totalWorth for SAVINGS balance" do
    balance_data = {
      "id" => "10000002",
      "amount" => { "value" => 4000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 5000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }

    @jar.update!(name: nil)
    @jar.upsert_wise_snapshot!(balance_data)

    assert_equal BigDecimal("5000.0"), @jar.current_balance
    assert_equal "Jar", @jar.name
  end

  test "upsert_wise_snapshot! stores borderless_account_id in raw_payload" do
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" }
    }

    @checking.upsert_wise_snapshot!(balance_data, borderless_account_id: 88888001, recipient_id: 99999001)

    assert_equal 88888001, @checking.raw_payload["borderless_account_id"]
    assert_equal 99999001, @checking.raw_payload["recipient_id"]
  end

  test "upsert_wise_snapshot! preserves existing name" do
    @checking.update!(name: "My Wise EUR")
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "name" => "Jar"
    }

    @checking.upsert_wise_snapshot!(balance_data)

    assert_equal "My Wise EUR", @checking.name
  end

  test "upsert_wise_snapshot! defaults name to Wise JAR currency for new SAVINGS account" do
    @jar.update!(name: nil)
    balance_data = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS"
    }

    @jar.upsert_wise_snapshot!(balance_data)

    assert_equal "Wise JAR EUR", @jar.name
  end
end
