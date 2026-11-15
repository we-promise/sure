require "test_helper"

class TagsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @other_family_user = users(:empty)

    # Verify cross-family isolation setup is correct
    assert_not_equal @user.family_id, @other_family_user.family_id,
      "Test setup error: @other_family_user must belong to a different family"
  end

  test "should get index" do
    get tags_url
    assert_response :success

    @user.family.tags.each do |tag|
      assert_select "#" + dom_id(tag), count: 1
    end
  end

  test "index offers the deletion dialog only for tags on transactions, without a query per tag" do
    used = tags(:one)
    unused = tags(:three)
    assert used.transactions.any?
    assert_not unused.transactions.any?

    # Each capture follows a write, which clears the query cache tests keep
    # across requests.
    @user.family.tags.create!(name: "Unused A")
    queries_with_few = capture_sql_queries { get tags_url }.size
    3.times { |i| @user.family.tags.create!(name: "Unused #{i + 1}") }
    queries_with_more = capture_sql_queries { get tags_url }.size

    assert_response :success
    assert_equal queries_with_few, queries_with_more
    assert_select "##{dom_id(used)} a[href='#{new_tag_deletion_path(used)}']", count: 1
    assert_select "##{dom_id(unused)} form[action='#{tag_path(unused)}']", count: 1
    assert_select "##{dom_id(unused)} a[href='#{new_tag_deletion_path(unused)}']", count: 0
  end

  test "should get new" do
    get new_tag_url
    assert_response :success
  end

  test "should create tag" do
    assert_difference("Tag.count") do
      post tags_url, params: { tag: { name: "Test Tag" } }
    end

    assert_redirected_to tags_url
    assert_equal "Tag created", flash[:notice]
  end

  test "guest cannot create tag" do
    sign_in family_guest

    assert_no_difference("Tag.count") do
      post tags_url, params: { tag: { name: "Guest Tag" } }
    end

    assert_redirected_to accounts_url
  end

  test "guest cannot destroy tag" do
    sign_in family_guest
    tag = tags(:one)

    assert_no_difference("Tag.count") do
      delete tag_url(tag)
    end

    assert_redirected_to accounts_url
  end

  test "member can create tag" do
    sign_in users(:family_member)

    assert_difference("Tag.count") do
      post tags_url, params: { tag: { name: "Member Tag" } }
    end

    assert_redirected_to tags_url
  end

  test "should create tag as json" do
    assert_difference("Tag.count") do
      post tags_url(format: :json), params: { tag: { name: "Quick Tag", color: "#e99537" } }
    end

    assert_response :created

    response_body = JSON.parse(response.body)
    assert_equal "Quick Tag", response_body["name"]
    assert_equal "#e99537", response_body["color"]
    assert response_body["id"].present?
    assert_includes response_body["html"], "data-tag-select-target=\"option\""
    assert_includes response_body["html"], "data-tag-id=\"#{response_body["id"]}\""
    assert_includes response_body["html"], "data-tag-select-badge"
  end

  test "should return json validation errors" do
    assert_no_difference("Tag.count") do
      post tags_url(format: :json), params: { tag: { name: "" } }
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["errors"].present?
  end

  test "should get edit" do
    get edit_tag_url(tags.first)
    assert_response :success
  end

  test "should update tag" do
    patch tag_url(tags.first), params: { tag: { name: "Test Tag" } }

    assert_redirected_to tags_url
    assert_equal "Tag updated", flash[:notice]
  end
end
