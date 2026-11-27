require "test_helper"

class TruelayerAccountTest < ActiveSupport::TestCase
  setup do
    @item = TruelayerItem.create!(family: families(:empty), name: "Globex", client_id: "sure-test", client_secret: "secret")
  end

  test "names repeated multi-currency balances after the bank and currency" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "Jane Doe", "GBP", "Globex"),
      snapshot("a2", "Jane Doe", "USD", "Globex"),
      snapshot("a3", "Savings", "EUR", "Globex")
    ])

    assert_equal({ "a1" => "Globex (GBP)", "a2" => "Globex (USD)", "a3" => "Globex (EUR)" }, names)
  end

  test "prefers the connection's bank name over the per-account provider name" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "Jane Doe", "GBP", "GLOBEX PAYMENTS LTD"),
      snapshot("a2", "Jane Doe", "USD", "GLOBEX PAYMENTS LTD")
    ], institution: "Globex")
    card = @item.truelayer_accounts.new
    card.upsert_truelayer_snapshot!(snapshot("c1", "Gold", "GBP", "ACME CARDS LTD", kind: "card"), institution: "Acme Cards")

    assert_equal({ "a1" => "Globex (GBP)", "a2" => "Globex (USD)" }, names)
    assert_equal "Acme Cards - Gold", card.name
    assert_equal "Acme Cards", card.institution_metadata["name"]
  end

  test "keeps bank names when a connection repeats none, and adds card digits" do
    names = TruelayerAccount.display_names([
      snapshot("a1", "EVERYDAY ACCOUNT", "GBP", "Acme Bank"),
      snapshot("c1", "REWARDS CARD", "GBP", "Acme Bank", kind: "card", partial_card_number: "4242")
    ])

    assert_equal({ "a1" => "EVERYDAY ACCOUNT", "c1" => "REWARDS CARD ••4242" }, names)
  end

  test "prefixes the institution unless the name already starts with it" do
    acme = @item.truelayer_accounts.new
    acme.upsert_truelayer_snapshot!(snapshot("a1", "EVERYDAY ACCOUNT", "GBP", "Acme Bank"))
    globex = @item.truelayer_accounts.new
    globex.upsert_truelayer_snapshot!(snapshot("a2", "x", "USD", "Globex"), display_name: "Globex (USD)")

    assert_equal "Acme Bank - EVERYDAY ACCOUNT", acme.name
    assert_equal "Globex (USD)", globex.name
    assert_equal "USD", globex.currency
  end

  test "merging keeps stored history, replaces updated transactions and skips pending ones" do
    account = @item.truelayer_accounts.create!(account_id: "a1", name: "Acc", currency: "GBP")
    account.merge_truelayer_transactions!([ txn("old", -1, "2020-01-01"), txn("same", -2, "2026-01-01") ])

    account.merge_truelayer_transactions!([ txn("same", -3, "2026-01-01"), txn("pend", -4, "2026-01-02", status: "pending") ])

    stored = account.reload.raw_transactions_payload.to_h { |t| [ t["transaction_id"], t["amount"] ] }
    assert_equal({ "old" => -1, "same" => -3 }, stored)
  end

  test "suggests a depository subtype from the account's name" do
    assert_equal "checking", @item.truelayer_accounts.new(name: "Acme Bank - Current Account").suggested_depository_subtype
    assert_equal "savings", @item.truelayer_accounts.new(name: "Instant Savings").suggested_depository_subtype
    assert_nil @item.truelayer_accounts.new(name: "Rewards Card").suggested_depository_subtype
  end

  private

    def snapshot(id, name, currency, institution, kind: "account", **extra)
      { account_id: id, display_name: name, currency: currency, kind: kind, account_type: "TRANSACTION", provider: { display_name: institution, provider_id: "ob-#{institution.parameterize}" } }.merge(extra)
    end

    def txn(id, amount, date, **extra)
      { transaction_id: id, amount: amount, timestamp: "#{date}T00:00:00Z", currency: "GBP", description: "x" }.merge(extra)
    end
end
