require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "destroying parent category preserves subcategory transaction assignments" do
    parent = @family.categories.create!(
      name: "Parent With Child Transactions",
      color: "#000000",
      lucide_icon: "folder"
    )
    subcategory = @family.categories.create!(
      name: "Child With Transactions",
      color: "#111111",
      lucide_icon: "folder",
      parent: parent
    )
    transaction = Transaction.create!(category: subcategory)

    assert_difference "Category.count", -1 do
      parent.destroy!
    end

    assert_nil subcategory.reload.parent_id
    assert_equal subcategory, transaction.reload.category
  end

  test "invalid parent_id does not raise during validation" do
    category = Category.new(
      name: "Orphan Subcategory",
      color: "#000000",
      lucide_icon: "folder",
      family: @family,
      parent_id: SecureRandom.uuid
    )

    assert_nothing_raised { category.valid? }
    assert_not category.subcategory?
    assert_nil category.parent
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "all_investment_contributions_names returns all locale variants" do
    names = Category.all_investment_contributions_names

    assert_includes names, "Investment Contributions"  # English
    assert_includes names, "Contributions aux investissements"  # French
    assert_includes names, "Investeringsbijdragen"  # Dutch
    assert names.all? { |name| name.is_a?(String) }
    assert_equal names, names.uniq  # No duplicates
  end

  test "display_name localizes default category names" do
    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮", categories(:food_and_drink).display_name
      assert_equal "未分类", Category.uncategorized.display_name
    end
  end

  test "display_name returns default category names in english" do
    I18n.with_locale(:en) do
      assert_equal "Food & Drink", categories(:food_and_drink).display_name
      assert_equal "Uncategorized", Category.uncategorized.display_name
    end
  end

  test "display_name preserves custom category names" do
    category = Category.new(name: "School Supplies", color: "#123456", lucide_icon: "book", family: @family)

    I18n.with_locale(:"zh-CN") do
      assert_equal "School Supplies", category.display_name
    end
  end

  test "display_name_with_parent localizes default parent and child names" do
    category = Category.new(
      name: "Groceries",
      color: "#123456",
      lucide_icon: "shopping-bag",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > 杂货", category.display_name_with_parent
    end
  end

  test "display_name_with_parent preserves custom child names" do
    category = Category.new(
      name: "Coffee Beans",
      color: "#123456",
      lucide_icon: "coffee",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > Coffee Beans", category.display_name_with_parent
    end
  end

  test "should accept valid 6-digit hex colors" do
    [ "#FFFFFF", "#000000", "#123456", "#ABCDEF", "#abcdef" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert category.valid?, "#{color} should be valid"
    end
  end

  test "should reject invalid colors" do
    [ "invalid", "#123", "#1234567", "#GGGGGG", "red", "ffffff", "#ffff", "" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert_not category.valid?, "#{color} should be invalid"
      assert_includes category.errors[:color], "is invalid"
    end
  end

  test "ids_with_transactions returns a lookup hash for categorized transactions" do
    category = categories(:food_and_drink)
    transaction = Transaction.create!(category: category)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Lookup transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    lookup = Category.ids_with_transactions(family: @family, category_ids: [ category.id, 0 ])

    assert lookup.key?(category.id)
    assert_not lookup.key?(0)
  end
end
