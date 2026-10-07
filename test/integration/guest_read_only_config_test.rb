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

    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
  end

  test "guest cannot import family configuration" do
    assert_no_difference("Import.count") do
      %w[CategoryImport MerchantImport RuleImport SureImport].each do |type|
        post imports_path, params: { import: { type: type } }
        assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
      end
    end

    import = family_guest.family.imports.create!(type: "MerchantImport")
    Import.any_instance.expects(:publish_later).never
    post publish_import_path(import)
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
  end

  test "guest cannot revert, cancel or delete a family configuration import" do
    import = family_guest.family.imports.create!(type: "SureImport", status: :complete)
    Import.any_instance.expects(:revert_later).never
    Import.any_instance.expects(:force_fail!).never

    put revert_import_path(import)
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]

    post cancel_import_path(import)
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]

    assert_no_difference("Import.count") do
      delete import_path(import)
    end
    assert_equal I18n.t("shared.require_non_guest"), flash[:alert]
  end

  test "guest cannot revert or delete an import whose created accounts they cannot write" do
    import = family_guest.family.imports.create!(type: "TransactionImport", status: :complete)
    account = family_guest.family.accounts.create!(
      name: "Imported by admin", balance: 0, currency: "USD", accountable: Depository.new,
      owner: users(:family_admin), import: import
    )
    Import.any_instance.expects(:revert_later).never

    put revert_import_path(import)
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]

    assert_no_difference([ "Import.count", "Account.count" ]) do
      delete import_path(import)
    end
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert account.reload.persisted?
  end

  test "guest cannot publish an import that would create categories or tags" do
    import = family_guest.family.imports.create!(type: "TransactionImport")
    import.mappings.create!(type: "Import::CategoryMapping", key: "Guest category", create_when_empty: true)
    Import.any_instance.expects(:publish_later).never

    post publish_import_path(import)

    assert_equal I18n.t("imports.publish.guest_new_categories_or_tags"), flash[:alert]
  end

  test "guest gets 403 instead of a redirect when a non-HTML revert is not allowed" do
    import = family_guest.family.imports.create!(type: "TransactionImport", status: :complete)
    family_guest.family.accounts.create!(
      name: "Imported by admin", balance: 0, currency: "USD", accountable: Depository.new,
      owner: users(:family_admin), import: import
    )
    Import.any_instance.expects(:revert_later).never

    put revert_import_path(import), as: :turbo_stream

    assert_response :forbidden
  end

  test "guest does not see revert or delete for family configuration imports" do
    complete = family_guest.family.imports.create!(type: "RuleImport", status: :complete)
    pending = family_guest.family.imports.create!(type: "CategoryImport")

    get imports_path

    assert_response :success
    assert_select "form[action=?]", revert_import_path(complete), count: 0
    assert_select "form[action=?]", import_path(pending), count: 0
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
