require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    assert_difference "Tag.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    old_tag.transactions.each do |txn|
      txn.reload
      assert_includes txn.tags, new_tag
      assert_not_includes txn.tags, old_tag
    end
  end

  test "ids_with_transactions lists only the given tags that are on a transaction" do
    family = families(:dylan_family)
    ids = Tag.ids_with_transactions(family: family, tag_ids: [ tags(:one).id, tags(:two).id, tags(:three).id ])

    assert_equal({ tags(:one).id => true, tags(:two).id => true }, ids)
    assert_equal({}, Tag.ids_with_transactions(family: families(:empty), tag_ids: [ tags(:one).id ]))
    assert_equal({}, Tag.ids_with_transactions(family: family, tag_ids: []))
  end

  test "rejects the reserved Untagged filter sentinel as a name" do
    tag = families(:dylan_family).tags.new(name: Tag::UNTAGGED_FILTER_VALUE, color: "#e99537")

    assert_not tag.valid?
    assert_includes tag.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic Untagged tag and the name for real tags" do
    assert_equal Tag::UNTAGGED_FILTER_VALUE, Tag.untagged.filter_value
    assert_equal tags(:one).name, tags(:one).filter_value
  end
end
