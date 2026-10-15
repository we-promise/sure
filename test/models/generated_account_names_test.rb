require "test_helper"

# Providers that build a default account name from the account number keep
# only its last 4 characters, because the name shows up in lists, reports,
# exports, the API and the assistant.
class GeneratedAccountNamesTest < ActiveSupport::TestCase
  test "Questrade names the account after the masked number" do
    account = questrade_accounts(:one)

    account.upsert_from_questrade!({ number: "53999999", type: "TFSA", status: "Active" })

    assert_equal "TFSA (•••9999)", account.reload.name
    assert_equal "53999999", account.questrade_account_id
  end

  test "Fio falls back to the masked account number" do
    account = fio_items(:one).fio_accounts.new(currency: "CZK")

    account.upsert_fio_snapshot!({ accountId: "2400333333", bankId: "2010", currency: "CZK" })

    assert_equal "Fio banka •••3333", account.reload.name
  end

  test "Trade Republic masks the brokerage account id" do
    importer = TradeRepublicItem::Importer.new(trade_republic_items(:configured_item), provider: nil)

    assert_equal "#{I18n.t("trade_republic_items.defaults.name")} Cash (•••6789)",
      importer.send(:build_account_name, "123456789", kind: "cash")
  end

  test "Trading 212 masks the account id" do
    importer = Trading212Item::Importer.new(trading212_items(:configured_item), provider: nil)

    assert_equal "#{I18n.t("trading212_items.defaults.name")} (•••4321)",
      importer.send(:build_account_name, "87654321")
  end
end
