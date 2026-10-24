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

  test "rejects the reserved Uncategorized filter sentinel as a name" do
    category = Category.new(name: Category::UNCATEGORIZED_FILTER_VALUE, color: "#123456", lucide_icon: "folder", family: @family)

    assert_not category.valid?
    assert_includes category.errors[:name], "is reserved"
  end

  test "filter_value returns the sentinel for the synthetic Uncategorized category and the name for real categories" do
    assert_equal Category::UNCATEGORIZED_FILTER_VALUE, Category.uncategorized.filter_value
    assert_equal categories(:food_and_drink).name, categories(:food_and_drink).filter_value
  end

  test "filter_value stays the sentinel even when read under a different locale than it was built in" do
    # Regression test: filter_value must not rely on a locale-sensitive name
    # comparison (uncategorized? checks name against I18n.t in the *current*
    # locale), or a synthetic instance built under one locale and read under
    # another would silently stop matching.
    synthetic = I18n.with_locale(:"zh-CN") { Category.uncategorized }

    I18n.with_locale(:en) do
      assert_equal Category::UNCATEGORIZED_FILTER_VALUE, synthetic.filter_value
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

  test "alphabetically_by_hierarchy orders a category's subcategories immediately after it" do
    ordered = @family.categories.alphabetically_by_hierarchy.to_a

    parent_index = ordered.index(categories(:food_and_drink))
    child_index = ordered.index(categories(:subcategory))

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "recently_used_for orders by last_used_at, most recent first" do
    older = categories(:income)
    newer = categories(:food_and_drink)
    older.update!(last_used_at: 2.days.ago)
    newer.update!(last_used_at: 1.day.ago)

    assert_equal [ newer, older ], Category.recently_used_for(family: @family).to_a
  end

  test "recently_used_for excludes categories with no usage yet" do
    categories(:food_and_drink).update!(last_used_at: 1.day.ago)

    assert_not_includes Category.recently_used_for(family: @family).to_a, categories(:income)
  end

  test "recently_used_for excludes given categories and respects limit" do
    a = categories(:income)
    b = categories(:food_and_drink)
    c = categories(:subcategory)
    a.update!(last_used_at: 3.days.ago)
    b.update!(last_used_at: 2.days.ago)
    c.update!(last_used_at: 1.day.ago)

    result = Category.recently_used_for(family: @family, excluding: b, limit: 1)

    assert_equal [ c ], result.to_a
  end
  test "emoji preserves complete Unicode sequences and the lucide fallback" do
    category = categories(:food_and_drink)
    category.update!(lucide_icon: "utensils")
    [ "😀", "☕️", "👨‍👩‍👧‍👦", "👩🏽‍💻", "🇨🇳", "1️⃣", "❤", "❤️", "🏴\u{E0067 E0062 E0065 E006E E0067 E007F}" ].each do |emoji|
      category.update!(emoji: emoji)
      assert_equal emoji, category.reload.emoji
      assert_equal "utensils", category.lucide_icon
    end
  end

  test "blank emoji clears the override without changing its fallback" do
    category = categories(:food_and_drink)
    [ nil, "", " \t\n " ].each do |blank|
      category.update!(emoji: "👩🏽‍💻", lucide_icon: "coffee")
      category.update!(emoji: blank)
      assert_nil category.reload.emoji
      assert_equal "coffee", category.lucide_icon
    end
    category.update!(emoji: "  👩🏽‍💻  ")
    assert_equal "👩🏽‍💻", category.reload.emoji
  end

  test "emoji rejects ordinary text multiple clusters incomplete sequences and oversized input" do
    category = categories(:food_and_drink)
    [ "abc", "1", "*", "a\u0308", "😀😀", "😀\u200D", "<script>alert(1)</script>", "😀" + "\u0301" * 70 ].each do |invalid|
      category.emoji = invalid
      assert_not category.valid?, "#{invalid.inspect} must not be accepted as one emoji"
      assert category.errors.of_kind?(:emoji, :invalid)
    end
  end

  test "emoji rejects invalid UTF-8 without raising during normalization" do
    category = categories(:food_and_drink)
    category.emoji = "\xFF".dup.force_encoding(Encoding::UTF_8)
    assert_nothing_raised { assert_not category.valid? }
    assert category.errors.of_kind?(:emoji, :invalid)
  end

  test "subcategory emoji stays independent while retaining inherited color and hierarchy" do
    parent = categories(:food_and_drink)
    child = categories(:subcategory)
    parent.update!(emoji: "🍽️")
    child.update!(emoji: "🍜")

    assert_equal parent.id, child.reload.parent_id
    assert_equal parent.color, child.color
    assert_equal "🍜", child.emoji
    assert_equal "🍽️", parent.reload.emoji
    child.update!(emoji: nil)
    assert_nil child.reload.emoji
    assert_equal "🍽️", parent.reload.emoji
  end

  test "emoji defaults leave existing and synthetic categories on lucide icons" do
    assert_nil categories(:food_and_drink).emoji
    assert_equal "shapes", categories(:food_and_drink).lucide_icon
    assert_nil Category.uncategorized.emoji
    assert_equal "circle-dashed", Category.uncategorized.lucide_icon
  end
end
