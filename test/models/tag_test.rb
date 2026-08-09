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

  test "replace and destroy destroys pockets linked to the destroyed tag" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    pocket = pockets(:vacation)

    assert_equal old_tag, pocket.tag

    assert_difference "Pocket.count", -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    assert_not Pocket.exists?(pocket.id)
  end

  test "destroy without replacement destroys pockets linked to the tag" do
    tag = tags(:one)
    pocket = pockets(:vacation)

    assert_equal tag, pocket.tag

    assert_difference "Pocket.count", -1 do
      tag.destroy!
    end

    assert_not Pocket.exists?(pocket.id)
  end
end
