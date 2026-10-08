require "test_helper"

class TagTest < ActiveSupport::TestCase
  test "replace and destroy moves the tag and tags nothing twice" do
    old_tag = tags(:one)
    new_tag = tags(:two)

    # The fixture transaction already carries both tags; this one carries
    # only the tag being replaced.
    already_tagged = transactions(:one)
    moved = transactions(:transfer_out)
    moved.taggings.create!(tag: old_tag)

    assert_difference [ "Tag.count", "Tagging.count" ], -1 do
      old_tag.replace_and_destroy!(new_tag)
    end

    assert_equal [ new_tag ], already_tagged.reload.tags.to_a
    assert_equal [ new_tag ], moved.reload.tags.to_a
  end

  # The unique index treats a missing taggable_type as a value, so the merge
  # has to as well, or it moves the row into a duplicate and fails.
  test "replace and destroy skips a row with no taggable type that the replacement already has" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    taggable_id = transactions(:transfer_out).id
    Tagging.insert_all!([ old_tag, new_tag ].map do |tag|
      { tag_id: tag.id, taggable_id: taggable_id, taggable_type: nil, created_at: Time.current, updated_at: Time.current }
    end)

    old_tag.replace_and_destroy!(new_tag)

    assert_equal [ new_tag.id ], Tagging.where(taggable_id: taggable_id).pluck(:tag_id)
  end

  # The unique index folds a missing taggable_type to '', so the merge must
  # treat a NULL type and an empty one as the same object too, or moving the
  # row would hit the index.
  test "replace and destroy treats a missing and an empty taggable type as the same object" do
    old_tag = tags(:one)
    new_tag = tags(:two)
    taggable_id = transactions(:transfer_out).id
    Tagging.insert_all!([
      { tag_id: old_tag.id, taggable_id: taggable_id, taggable_type: nil, created_at: Time.current, updated_at: Time.current },
      { tag_id: new_tag.id, taggable_id: taggable_id, taggable_type: "", created_at: Time.current, updated_at: Time.current }
    ])

    old_tag.replace_and_destroy!(new_tag)

    assert_equal [ new_tag.id ], Tagging.where(taggable_id: taggable_id).pluck(:tag_id)
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
