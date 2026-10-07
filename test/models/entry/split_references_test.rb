require "test_helper"

class Entry::SplitReferencesTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
  end

  test "keeps the family's own ids" do
    references = Entry::SplitReferences.new(@family)

    scoped = references.scope(
      category_id: categories(:food_and_drink).id,
      merchant_id: merchants(:netflix).id,
      tag_ids: [ tags(:one).id, "", tags(:one).id ]
    )

    assert_equal categories(:food_and_drink).id, scoped[:category_id]
    assert_equal merchants(:netflix).id, scoped[:merchant_id]
    assert_equal [ tags(:one).id ], scoped[:tag_ids]
  end

  test "drops foreign and unknown ids" do
    foreign_category = @other_family.categories.create!(name: "Foreign", color: "#000000")
    foreign_merchant = @other_family.merchants.create!(name: "Foreign Shop")
    foreign_tag = @other_family.tags.create!(name: "Foreign")

    scoped = Entry::SplitReferences.new(@family).scope(
      category_id: foreign_category.id,
      merchant_id: foreign_merchant.id,
      tag_ids: [ foreign_tag.id, SecureRandom.uuid ]
    )

    assert_equal({ category_id: nil, merchant_id: nil, tag_ids: [] }, scoped)
  end

  test "uses the given merchant scope instead of family merchants" do
    provider_merchant = ProviderMerchant.create!(name: "Provider Shop", source: "plaid", provider_merchant_id: "split-ref-1")

    family_only = Entry::SplitReferences.new(@family)
    with_provider = Entry::SplitReferences.new(@family, merchants: Merchant.where(id: provider_merchant.id))

    assert_nil family_only.scope(category_id: nil, merchant_id: provider_merchant.id, tag_ids: nil)[:merchant_id]
    assert_equal provider_merchant.id, with_provider.scope(category_id: nil, merchant_id: provider_merchant.id, tag_ids: nil)[:merchant_id]
  end
end
