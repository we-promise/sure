require "test_helper"

class PlaidItem::AccountOverlapTest < ActiveSupport::TestCase
  FakeItem = Struct.new(:plaid_accounts)
  FakeAccount = Struct.new(:name, :mask)

  setup do
    @item = FakeItem.new([ FakeAccount.new("Plaid Checking", "0000"), FakeAccount.new("Plaid Saving", "1111") ])
  end

  test "all accounts are connected when every reported account matches by name and mask" do
    overlap = overlap_for([ reported("Plaid Checking", "0000"), reported("Plaid Saving", "1111") ])

    assert_equal :all_connected, overlap.state
    assert_equal 2, overlap.connected_count
    assert_empty overlap.unconnected_accounts
  end

  test "some accounts are connected when only part of the new connection matches" do
    overlap = overlap_for([ reported("Plaid Checking", "0000"), reported("Plaid HSA", "7777") ])

    assert_equal :some_connected, overlap.state
    assert_equal [ reported("Plaid HSA", "7777") ], overlap.unconnected_accounts
    assert_equal 1, overlap.connected_count
  end

  test "no accounts are connected when nothing reported matches" do
    overlap = overlap_for([ reported("Business Checking", "9999") ])

    assert_equal :none_connected, overlap.state
    assert_equal 0, overlap.connected_count
  end

  # Plaid often names accounts generically ("Plaid Checking", "Checking"), so a second
  # login's accounts can share names with the first's. The mask has to agree too.
  test "a matching name with a different mask is not connected" do
    overlap = overlap_for([ reported("Plaid Checking", "4242") ])

    assert_equal :none_connected, overlap.state
  end

  test "names match regardless of case and surrounding whitespace" do
    overlap = overlap_for([ reported("  plaid CHECKING ", "0000") ])

    assert_equal :all_connected, overlap.state
  end

  test "every matching connection counts" do
    other = FakeItem.new([ FakeAccount.new("Plaid HSA", "7777") ])

    overlap = overlap_for([ reported("Plaid Checking", "0000"), reported("Plaid HSA", "7777") ], items: [ @item, other ])

    assert_equal :all_connected, overlap.state
  end

  test "the comparison is unknown when Link reports no accounts" do
    assert_equal :unknown, overlap_for([]).state
    assert_equal :unknown, overlap_for(nil).state
  end

  # A connection whose first sync never landed has no accounts on record, so anything
  # Link reported might be one of its accounts -- "none connected" would be a guess.
  test "the comparison is unknown when a matching connection has no accounts on record" do
    unsynced = FakeItem.new([])

    overlap = overlap_for([ reported("Business Checking", "9999") ], items: [ @item, unsynced ])

    assert_equal :unknown, overlap.state
  end

  # Brokerages and crypto exchanges often report no mask and generic names such as
  # "Brokerage", so a different login's accounts can match a connected one on name
  # alone. That is too little to call them the same, and an all-connected verdict
  # would take away the dialog's override.
  test "the comparison is unknown when a reported account has no mask" do
    brokerage = FakeItem.new([ FakeAccount.new("Brokerage", nil) ])

    assert_equal :unknown, overlap_for([ reported("Brokerage", nil) ], items: [ brokerage ]).state
    assert_equal :unknown, overlap_for([ reported("Brokerage", ""), reported("Plaid Checking", "0000") ], items: [ brokerage, @item ]).state
  end

  # A family can hold several connections at one institution, often for different
  # logins. Only those holding a reported account are what this link overlaps.
  test "matching items are the connections holding a reported account" do
    business = FakeItem.new([ FakeAccount.new("Business Checking", "9999") ])

    overlap = overlap_for([ reported("Plaid Checking", "0000") ], items: [ @item, business ])

    assert_equal [ @item ], overlap.matching_items
  end

  test "matching items are empty when nothing reported matches" do
    business = FakeItem.new([ FakeAccount.new("Business Checking", "9999") ])

    overlap = overlap_for([ reported("Other Checking", "4242") ], items: [ @item, business ])

    assert_equal :none_connected, overlap.state
    assert_empty overlap.matching_items
  end

  test "reported accounts may arrive with symbol keys" do
    overlap = overlap_for([ { name: "Plaid Checking", mask: "0000" } ])

    assert_equal :all_connected, overlap.state
  end

  private
    def overlap_for(link_accounts, items: [ @item ])
      PlaidItem::AccountOverlap.new(link_accounts: link_accounts, plaid_items: items)
    end

    def reported(name, mask)
      { "name" => name, "mask" => mask }
    end
end
