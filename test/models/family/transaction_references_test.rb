require "test_helper"

class Family::TransactionReferencesTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @other_family = families(:empty)
  end

  test "resolves the family's own category and rejects a foreign or malformed one" do
    foreign = @other_family.categories.create!(name: "Foreign", color: "#000000", lucide_icon: "folder")

    assert_equal categories(:food_and_drink).id, @family.transaction_category_id_for(categories(:food_and_drink).id)
    assert_nil @family.transaction_category_id_for(foreign.id)
    assert_nil @family.transaction_category_id_for("not-a-uuid")
    assert_nil @family.transaction_category_id_for("")
  end

  test "resolves merchants the picker offers, including provider merchants on visible transactions" do
    foreign = @other_family.merchants.create!(name: "Foreign Merchant")
    provider = ProviderMerchant.create!(name: "Provider Coffee", source: "enable_banking")
    unseen_provider = ProviderMerchant.create!(name: "Provider Elsewhere", source: "enable_banking")
    accounts(:depository).entries.create!(
      name: "Coffee", date: Date.current, amount: 5, currency: "USD", entryable: Transaction.new(merchant: provider)
    )

    assert_equal merchants(:netflix).id, @family.transaction_merchant_id_for(merchants(:netflix).id, user: @user)
    assert_equal provider.id, @family.transaction_merchant_id_for(provider.id, user: @user)
    assert_nil @family.transaction_merchant_id_for(unseen_provider.id, user: @user)
    assert_nil @family.transaction_merchant_id_for(foreign.id, user: @user)
  end

  test "keeps only the family's own tag ids" do
    foreign = @other_family.tags.create!(name: "Foreign Tag")

    assert_equal [ tags(:one).id ], @family.transaction_tag_ids_for([ tags(:one).id, foreign.id, "" ])
    assert_equal [], @family.transaction_tag_ids_for(nil)
  end
end
