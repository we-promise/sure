require "test_helper"

class Tag::DeletionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @tag = tags(:one)
  end

  test "should get new" do
    get new_tag_deletion_url(@tag)
    assert_response :success
  end

  test "create with replacement" do
    replacement_tag = tags(:two)

    # The fixture transaction already carries both tags, so it must end up
    # with the replacement once; this one only carries the deleted tag.
    already_tagged = transactions(:one)
    moved = transactions(:transfer_out)
    moved.taggings.create!(tag: @tag)

    assert_difference -> { Tag.count } => -1, -> { Tagging.count } => -1 do
      post tag_deletions_url(@tag), params: { replacement_tag_id: replacement_tag.id }
    end

    assert_equal [ replacement_tag ], already_tagged.reload.tags.to_a
    assert_equal [ replacement_tag ], moved.reload.tags.to_a
  end

  test "create without replacement" do
    affected_transactions = @tag.transactions

    assert affected_transactions.count > 0

    assert_difference -> { Tag.count } => -1, -> { Tagging.count } => affected_transactions.count * -1 do
      post tag_deletions_url(@tag)
    end
  end

  test "create with invalid or cross-family tag_id returns not found" do
    other_family_tag = families(:empty).tags.create!(name: "Other family tag")

    assert_no_difference -> { Tag.count } do
      post tag_deletions_url(tag_id: other_family_tag.id)
    end

    assert_response :not_found
  end

  test "create with invalid replacement_tag_id returns not found" do
    assert_no_difference -> { Tag.count } do
      post tag_deletions_url(@tag), params: { replacement_tag_id: "missing" }
    end

    assert_response :not_found
  end
end
