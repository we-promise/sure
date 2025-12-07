require "test_helper"

class RuleImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      classification: "expense",
      lucide_icon: "shopping-basket"
    )
    @csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Categorize groceries","transaction",true,2024-01-01,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"grocery\"}]","[{\"action_type\":\"set_transaction_category\",\"value\":\"Groceries\"}]"
      "Auto-categorize transactions","transaction",false,,"[{\"condition_type\":\"transaction_amount\",\"operator\":\">\",\"value\":\"100\"}]","[{\"action_type\":\"auto_categorize\"}]"
    CSV
  end

  test "imports rules from CSV" do
    import = @family.imports.create!(type: "RuleImport", raw_file_str: @csv, col_sep: ",")
    import.generate_rows_from_csv
    assert_equal 2, import.rows.count

    assert_difference -> { Rule.where(family: @family).count }, 2 do
      import.send(:import!)
    end

    grocery_rule = Rule.find_by!(family: @family, name: "Categorize groceries")
    auto_rule = Rule.find_by!(family: @family, name: "Auto-categorize transactions")

    assert_equal "transaction", grocery_rule.resource_type
    assert grocery_rule.active
    assert_equal Date.parse("2024-01-01"), grocery_rule.effective_date
    assert_equal 1, grocery_rule.conditions.count
    assert_equal 1, grocery_rule.actions.count

    assert_equal "transaction", auto_rule.resource_type
    assert_not auto_rule.active
    assert_nil auto_rule.effective_date
    assert_equal 1, auto_rule.conditions.count
    assert_equal 1, auto_rule.actions.count
  end

  test "imports rule conditions correctly" do
    import = @family.imports.create!(type: "RuleImport", raw_file_str: @csv, col_sep: ",")
    import.generate_rows_from_csv
    import.send(:import!)

    grocery_rule = Rule.find_by!(family: @family, name: "Categorize groceries")
    condition = grocery_rule.conditions.first

    assert_equal "transaction_name", condition.condition_type
    assert_equal "like", condition.operator
    assert_equal "grocery", condition.value
  end

  test "imports rule actions correctly and maps category names to IDs" do
    import = @family.imports.create!(type: "RuleImport", raw_file_str: @csv, col_sep: ",")
    import.generate_rows_from_csv
    import.send(:import!)

    grocery_rule = Rule.find_by!(family: @family, name: "Categorize groceries")
    action = grocery_rule.actions.first

    assert_equal "set_transaction_category", action.action_type
    assert_equal @category.id, action.value
  end

  test "imports compound conditions with sub-conditions" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Complex rule","transaction",true,,"[{\"condition_type\":\"compound\",\"operator\":\"or\",\"sub_conditions\":[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"walmart\"},{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"target\"}]}]","[{\"action_type\":\"set_transaction_category\",\"value\":\"Groceries\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv
    import.send(:import!)

    rule = Rule.find_by!(family: @family, name: "Complex rule")
    assert_equal 1, rule.conditions.count

    compound_condition = rule.conditions.first
    assert compound_condition.compound?
    assert_equal "or", compound_condition.operator
    assert_equal 2, compound_condition.sub_conditions.count

    sub_condition_1 = compound_condition.sub_conditions.first
    assert_equal "transaction_name", sub_condition_1.condition_type
    assert_equal "like", sub_condition_1.operator
    assert_equal "walmart", sub_condition_1.value

    sub_condition_2 = compound_condition.sub_conditions.last
    assert_equal "transaction_name", sub_condition_2.condition_type
    assert_equal "like", sub_condition_2.operator
    assert_equal "target", sub_condition_2.value
  end

  test "creates missing categories when importing actions" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "New category rule","transaction",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"coffee\"}]","[{\"action_type\":\"set_transaction_category\",\"value\":\"Coffee Shops\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_difference -> { Category.where(family: @family).count }, 1 do
      import.send(:import!)
    end

    new_category = Category.find_by!(family: @family, name: "Coffee Shops")
    assert_equal Category::UNCATEGORIZED_COLOR, new_category.color
    assert_equal "expense", new_category.classification

    rule = Rule.find_by!(family: @family, name: "New category rule")
    action = rule.actions.first
    assert_equal new_category.id, action.value
  end

  test "creates missing tags when importing actions" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "New tag rule","transaction",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"coffee\"}]","[{\"action_type\":\"set_transaction_tags\",\"value\":\"Coffee Tag\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_difference -> { Tag.where(family: @family).count }, 1 do
      import.send(:import!)
    end

    new_tag = Tag.find_by!(family: @family, name: "Coffee Tag")

    rule = Rule.find_by!(family: @family, name: "New tag rule")
    action = rule.actions.first
    assert_equal "set_transaction_tags", action.action_type
    assert_equal new_tag.id, action.value
  end

  test "reuses existing tags when importing actions" do
    existing_tag = @family.tags.create!(name: "Existing Tag")

    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Tag rule","transaction",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"test\"}]","[{\"action_type\":\"set_transaction_tags\",\"value\":\"Existing Tag\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_no_difference -> { Tag.where(family: @family).count } do
      import.send(:import!)
    end

    rule = Rule.find_by!(family: @family, name: "Tag rule")
    action = rule.actions.first
    assert_equal "set_transaction_tags", action.action_type
    assert_equal existing_tag.id, action.value
  end

  test "updates existing rule when re-importing with same name" do
    # First import
    import1 = @family.imports.create!(type: "RuleImport", raw_file_str: @csv, col_sep: ",")
    import1.generate_rows_from_csv
    import1.send(:import!)

    original_rule = Rule.find_by!(family: @family, name: "Categorize groceries")
    assert original_rule.active

    # Second import with updated rule
    csv2 = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Categorize groceries","transaction",false,2024-02-01,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"market\"}]","[{\"action_type\":\"auto_categorize\"}]"
    CSV

    import2 = @family.imports.create!(type: "RuleImport", raw_file_str: csv2, col_sep: ",")
    import2.generate_rows_from_csv

    assert_no_difference -> { Rule.where(family: @family).count } do
      import2.send(:import!)
    end

    updated_rule = Rule.find_by!(family: @family, name: "Categorize groceries")
    assert_equal original_rule.id, updated_rule.id
    assert_not updated_rule.active
    assert_equal Date.parse("2024-02-01"), updated_rule.effective_date

    # Verify old conditions/actions are replaced
    condition = updated_rule.conditions.first
    assert_equal "market", condition.value

    action = updated_rule.actions.first
    assert_equal "auto_categorize", action.action_type
  end

  test "validates resource_type" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Invalid rule","invalid_type",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"test\"}]","[{\"action_type\":\"auto_categorize\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_raises ActiveRecord::RecordInvalid do
      import.send(:import!)
    end
  end

  test "validates at least one action exists" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "No actions rule","transaction",true,,"[{\"condition_type\":\"transaction_name\",\"operator\":\"like\",\"value\":\"test\"}]","[]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_raises ActiveRecord::RecordInvalid do
      import.send(:import!)
    end
  end

  test "handles invalid JSON in conditions or actions" do
    csv = <<~CSV
      name,resource_type,active,effective_date,conditions,actions
      "Bad JSON rule","transaction",true,,"invalid json","[{\"action_type\":\"auto_categorize\"}]"
    CSV

    import = @family.imports.create!(type: "RuleImport", raw_file_str: csv, col_sep: ",")
    import.generate_rows_from_csv

    assert_raises ActiveRecord::RecordInvalid do
      import.send(:import!)
    end
  end
end
