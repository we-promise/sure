require "test_helper"

class SaxoAccountTest < ActiveSupport::TestCase
  setup do
    @item = families(:dylan_family).saxo_items.create!
    @source = @item.saxo_accounts.create!(account_id: "123", name: "PEA", currency: "EUR", account_type: "PEA")
  end

  test "linking cannot cross families or attach another provider writer" do
    foreign = families(:empty).accounts.create!(name: "Foreign account", currency: "EUR", balance: 0, accountable: Investment.new(subtype: "brokerage"))
    assert_raises(ArgumentError) { @source.link!(foreign) }
    assert_nil @source.reload.account_provider

    linked = families(:dylan_family).accounts.create!(name: "Linked account", currency: "EUR", balance: 0, accountable: Investment.new(subtype: "brokerage"))
    @item.saxo_accounts.create!(account_id: "456", name: "CTO", currency: "EUR").link!(linked)
    assert_raises(ArgumentError) { @source.link!(linked) }
    assert_nil @source.reload.account_provider
  end

  test "linking requires an investment account in the Saxo account currency" do
    depository = families(:dylan_family).accounts.create!(name: "Checking", currency: "EUR", balance: 0, accountable: Depository.new)
    assert_raises(ArgumentError) { @source.link!(depository) }

    dollars = families(:dylan_family).accounts.create!(name: "Dollar brokerage", currency: "USD", balance: 0, accountable: Investment.new(subtype: "brokerage"))
    assert_raises(ArgumentError) { @source.link!(dollars) }

    assert_nil @source.reload.account_provider
  end

  test "PEA and PEA-PME map to the PEA subtype" do
    assert_equal "pea", @source.subtype
    @source.account_type = "PEA_PME"
    assert_equal "pea", @source.subtype
    @source.account_type = "None"
    assert_equal "brokerage", @source.subtype
  end
end
