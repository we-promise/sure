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
    pocket = pockets(:vacation)
    assert_equal @tag, pocket.tag

    affected_transaction_count = @tag.transactions.count

    assert affected_transaction_count > 0

    # A transaction already carrying both @tag and replacement_tag doesn't add
    # a *new* transaction to replacement_tag — the redundant tagging is
    # dropped rather than duplicated (see Tag#replace_and_destroy!).
    new_transaction_count = (@tag.transactions.to_a - replacement_tag.transactions.to_a).size

    assert_difference -> { Tag.count } => -1, -> { replacement_tag.transactions.count } => new_transaction_count, -> { Pocket.count } => -1 do
      post tag_deletions_url(@tag), params: { replacement_tag_id: replacement_tag.id }
    end

    assert_not Pocket.exists?(pocket.id)
  end

  test "create without replacement" do
    affected_transactions = @tag.transactions
    pocket = pockets(:vacation)
    assert_equal @tag, pocket.tag

    assert affected_transactions.count > 0

    assert_difference -> { Tag.count } => -1, -> { Tagging.count } => affected_transactions.count * -1, -> { Pocket.count } => -1 do
      post tag_deletions_url(@tag)
    end

    assert_not Pocket.exists?(pocket.id)
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
