require "test_helper"

class CategoryImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @csv = <<~CSV
      name,color,parent_category,classification,icon
      Food & Drink,#f97316,,expense,carrot
      Groceries,#407706,Food & Drink,expense,shopping-basket
      Salary,#22c55e,,income,briefcase
    CSV
  end

  test "imports categories from Sure export" do
    import = @family.imports.create!(type: "CategoryImport", raw_file_str: @csv, col_sep: ",")
    import.generate_rows_from_csv
    assert_equal 3, import.rows.count

    tracked_categories = Category.where(family: @family, name: [ "Food & Drink", "Groceries", "Salary" ])

    assert_difference -> { tracked_categories.count }, 2 do
      import.send(:import!)
    end

    food = Category.find_by!(family: @family, name: "Food & Drink")
    groceries = Category.find_by!(family: @family, name: "Groceries")
    salary = Category.find_by!(family: @family, name: "Salary")

    assert_equal "expense", food.classification
    assert_equal "carrot", food.lucide_icon
    assert_equal food, groceries.parent
    assert_equal "shopping-basket", groceries.lucide_icon
    assert_equal "income", salary.classification
    assert_equal "briefcase", salary.lucide_icon
  end

  test "imports subcategories even when parent row comes later" do
    csv = <<~CSV
      name,color,parent_category,classification,icon
      Utilities,#407706,Household,expense,plug
      Household,#f97316,,expense,house
    CSV

    import = @family.imports.create!(type: "CategoryImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    import.send(:import!)

    household = Category.find_by!(family: @family, name: "Household")
    utilities = Category.find_by!(family: @family, name: "Utilities")

    assert_equal household, utilities.parent
    assert_equal "#f97316", household.color
  end

  test "updates categories when duplicate rows are provided" do
    csv = <<~CSV
      name,color,parent_category,classification,icon
      Snacks,#aaaaaa,,expense,cookie
      Snacks,#bbbbbb,,expense,pizza
    CSV

    import = @family.imports.create!(type: "CategoryImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    import.send(:import!)

    snacks = Category.find_by!(family: @family, name: "Snacks")
    assert_equal "#bbbbbb", snacks.color
    assert_equal "pizza", snacks.lucide_icon
  end
end
