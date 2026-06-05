require "test_helper"

class Merchant::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @target = merchants(:netflix)
    @source = merchants(:amazon)
  end

  # Regression: issue #1977. Merging merchants reassigns merchant_id via
  # update_all; without flagging the entries as user_modified, the next
  # provider sync reverts the merge.
  test "merge! flags reassigned transactions as user_modified" do
    entry = create_transaction(merchant: @source)
    assert_not entry.user_modified?

    Merchant::Merger.new(family: @family, target_merchant: @target, source_merchants: [ @source ]).merge!

    entry.reload
    assert_equal @target.id, entry.entryable.merchant_id, "transaction is reassigned to the target merchant"
    assert entry.user_modified?, "merged transaction's entry must be flagged so provider sync won't revert it"
  end

  test "merge! does not touch entries of unrelated merchants" do
    other = create_transaction(merchant: @target)
    assert_not other.user_modified?

    Merchant::Merger.new(family: @family, target_merchant: @target, source_merchants: [ @source ]).merge!

    other.reload
    assert_not other.user_modified?, "transactions already on the target are untouched"
  end
end
