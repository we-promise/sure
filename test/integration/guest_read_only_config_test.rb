require "test_helper"

class GuestReadOnlyConfigTest < ActionDispatch::IntegrationTest
  setup do
    sign_in family_guest
  end

  test "guest can view family configuration" do
    [ categories_path, tags_path, rules_path, family_merchants_path ].each do |path|
      get path

      assert_response :success, "#{path} should stay readable for guests"
    end
  end

  test "guest cannot create categories, tags or merchants" do
    assert_no_difference([ "Category.count", "Tag.count", "FamilyMerchant.count" ]) do
      post categories_path, params: { category: { name: "Guest category", color: "#000000" } }
      post tags_path, params: { tag: { name: "Guest tag" } }
      post family_merchants_path, params: { family_merchant: { name: "Guest merchant" } }
    end
  end

  test "guest cannot update or delete existing configuration" do
    category = categories(:food_and_drink)
    tag = tags(:one)
    merchant = merchants(:netflix)

    patch category_path(category), params: { category: { name: "Renamed by guest" } }
    patch tag_path(tag), params: { tag: { name: "Renamed by guest" } }
    patch family_merchant_path(merchant), params: { family_merchant: { name: "Renamed by guest" } }

    assert_not_equal "Renamed by guest", category.reload.name
    assert_not_equal "Renamed by guest", tag.reload.name
    assert_not_equal "Renamed by guest", merchant.reload.name

    assert_no_difference([ "Category.count", "Tag.count", "FamilyMerchant.count", "Rule.count" ]) do
      delete category_path(category)
      delete tag_path(tag)
      delete family_merchant_path(merchant)
      delete destroy_all_categories_path
      delete destroy_all_tags_path
      delete destroy_all_rules_path
      post category_deletions_path(category)
      post tag_deletions_path(tag)
    end
  end

  test "guest cannot apply rules to family transactions" do
    Rule.any_instance.expects(:apply_later).never

    post apply_rule_path(rules(:one))
    post apply_all_rules_path

    assert_redirected_to root_path
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
  end

  test "guest does not see controls to change family configuration" do
    get categories_path
    assert_select "a[href=?]", new_category_path, count: 0
    assert_select "form[action=?]", destroy_all_categories_path, count: 0
    assert_select "[data-testid=category-actions]", count: 0

    get tags_path
    assert_select "a[href=?]", new_tag_path, count: 0
    assert_select "a[href=?]", edit_tag_path(tags(:one)), count: 0

    get rules_path
    assert_select "a[href=?]", new_rule_path(resource_type: "transaction"), count: 0
    assert_select "a[href=?]", confirm_all_rules_path, count: 0
    assert_select "a[href=?]", edit_rule_path(rules(:one)), count: 0
    assert_select "input[type=checkbox][name=?][disabled]", "rule[active]"

    get family_merchants_path
    assert_select "a[href=?]", new_family_merchant_path, count: 0
    assert_select "a[href=?]", edit_family_merchant_path(merchants(:netflix)), count: 0
  end

  test "members still see controls to change family configuration" do
    sign_in users(:family_member)

    get categories_path
    assert_select "a[href=?]", new_category_path
    assert_select "[data-testid=category-actions]"

    get tags_path
    assert_select "a[href=?]", edit_tag_path(tags(:one))

    get rules_path
    assert_select "a[href=?]", edit_rule_path(rules(:one))
    assert_select "input[type=checkbox][name=?]:not([disabled])", "rule[active]"

    get family_merchants_path
    assert_select "a[href=?]", edit_family_merchant_path(merchants(:netflix))
  end

  test "members can still manage family configuration" do
    sign_in users(:family_member)

    assert_difference("Tag.count", 1) do
      post tags_path, params: { tag: { name: "Member tag" } }
    end
  end
end
