require "test_helper"

class Family::DataExporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @exporter = Family::DataExporter.new(@family)

    # Create some test data for the family
    @account = @family.accounts.create!(
      name: "Test Account",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )

    @category = @family.categories.create!(
      name: "Test Category",
      color: "#FF0000"
    )

    @tag = @family.tags.create!(
      name: "Test Tag",
      color: "#00FF00"
    )

    @rule = @family.rules.build(
      name: "Test Rule",
      resource_type: "transaction",
      active: true
    )
    @rule.conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "test"
    )
    @rule.actions.build(
      action_type: "set_transaction_category",
      value: @category.id
    )
    @rule.save!
  end

  test "generates a zip file with all required files" do
    zip_data = @exporter.generate_export

    assert zip_data.is_a?(StringIO)

    # Check that the zip contains all expected files
    expected_files = [ "accounts.csv", "transactions.csv", "trades.csv", "categories.csv", "rules.csv", "all.ndjson" ]

    Zip::File.open_buffer(zip_data) do |zip|
      actual_files = zip.entries.map(&:name)
      assert_equal expected_files.sort, actual_files.sort
    end
  end

  test "generates valid CSV files" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      # Check accounts.csv
      accounts_csv = zip.read("accounts.csv")
      assert accounts_csv.include?("id,name,type,subtype,balance,currency,created_at")

      # Check transactions.csv
      transactions_csv = zip.read("transactions.csv")
      assert transactions_csv.include?("date,account_name,amount,name,category,tags,notes,currency")

      # Check trades.csv
      trades_csv = zip.read("trades.csv")
      assert trades_csv.include?("date,account_name,ticker,quantity,price,amount,currency")

      # Check categories.csv
      categories_csv = zip.read("categories.csv")
      assert categories_csv.include?("name,color,parent_category,classification,lucide_icon")

      # Check rules.csv
      rules_csv = zip.read("rules.csv")
      assert rules_csv.include?("name,resource_type,active,effective_date,conditions,actions")
    end
  end

  test "generates valid NDJSON file" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      lines.each do |line|
        assert_nothing_raised { JSON.parse(line) }
      end

      # Check that each line has expected structure
      first_line = JSON.parse(lines.first)
      assert first_line.key?("type")
      assert first_line.key?("data")
    end
  end

  test "only exports data from the specified family" do
    # Create data for another family that should NOT be exported
    other_account = @other_family.accounts.create!(
      name: "Other Family Account",
      accountable: Depository.new,
      balance: 5000,
      currency: "USD"
    )

    other_category = @other_family.categories.create!(
      name: "Other Family Category",
      color: "#0000FF"
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      # Check accounts.csv doesn't contain other family's data
      accounts_csv = zip.read("accounts.csv")
      assert accounts_csv.include?(@account.name)
      refute accounts_csv.include?(other_account.name)

      # Check categories.csv doesn't contain other family's data
      categories_csv = zip.read("categories.csv")
      assert categories_csv.include?(@category.name)
      refute categories_csv.include?(other_category.name)

      # Check NDJSON doesn't contain other family's data
      ndjson_content = zip.read("all.ndjson")
      refute ndjson_content.include?(other_account.id)
      refute ndjson_content.include?(other_category.id)
    end
  end

  test "exports rules in CSV format" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      rules_csv = zip.read("rules.csv")

      assert rules_csv.include?("Test Rule")
      assert rules_csv.include?("transaction")
      assert rules_csv.include?("true")
    end
  end

  test "exports rules in NDJSON format with versioning" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      rule_lines = lines.select do |line|
        parsed = JSON.parse(line)
        parsed["type"] == "Rule"
      end

      assert rule_lines.any?

      rule_data = JSON.parse(rule_lines.first)
      assert_equal "Rule", rule_data["type"]
      assert_equal 1, rule_data["version"]
      assert rule_data["data"].key?("name")
      assert rule_data["data"].key?("resource_type")
      assert rule_data["data"].key?("active")
      assert rule_data["data"].key?("conditions")
      assert rule_data["data"].key?("actions")
    end
  end

  test "exports rule conditions with proper structure" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      rule_lines = lines.select do |line|
        parsed = JSON.parse(line)
        parsed["type"] == "Rule" && parsed["data"]["name"] == "Test Rule"
      end

      assert rule_lines.any?

      rule_data = JSON.parse(rule_lines.first)
      conditions = rule_data["data"]["conditions"]

      assert_equal 1, conditions.length
      assert_equal "transaction_name", conditions[0]["condition_type"]
      assert_equal "like", conditions[0]["operator"]
      assert_equal "test", conditions[0]["value"]
    end
  end

  test "exports rule actions and maps category UUIDs to names" do
    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      rule_lines = lines.select do |line|
        parsed = JSON.parse(line)
        parsed["type"] == "Rule" && parsed["data"]["name"] == "Test Rule"
      end

      assert rule_lines.any?

      rule_data = JSON.parse(rule_lines.first)
      actions = rule_data["data"]["actions"]

      assert_equal 1, actions.length
      assert_equal "set_transaction_category", actions[0]["action_type"]
      # Should export category name instead of UUID
      assert_equal "Test Category", actions[0]["value"]
    end
  end

  test "exports rule actions and maps tag UUIDs to names" do
    # Create a rule with a tag action
    tag_rule = @family.rules.build(
      name: "Tag Rule",
      resource_type: "transaction",
      active: true
    )
    tag_rule.conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "test"
    )
    tag_rule.actions.build(
      action_type: "set_transaction_tags",
      value: @tag.id
    )
    tag_rule.save!

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      rule_lines = lines.select do |line|
        parsed = JSON.parse(line)
        parsed["type"] == "Rule" && parsed["data"]["name"] == "Tag Rule"
      end

      assert rule_lines.any?

      rule_data = JSON.parse(rule_lines.first)
      actions = rule_data["data"]["actions"]

      assert_equal 1, actions.length
      assert_equal "set_transaction_tags", actions[0]["action_type"]
      # Should export tag name instead of UUID
      assert_equal "Test Tag", actions[0]["value"]
    end
  end

  test "exports compound conditions with sub-conditions" do
    # Create a rule with compound conditions
    compound_rule = @family.rules.build(
      name: "Compound Rule",
      resource_type: "transaction",
      active: true
    )
    parent_condition = compound_rule.conditions.build(
      condition_type: "compound",
      operator: "or"
    )
    parent_condition.sub_conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "walmart"
    )
    parent_condition.sub_conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "target"
    )
    compound_rule.actions.build(
      action_type: "auto_categorize"
    )
    compound_rule.save!

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      lines = ndjson_content.split("\n")

      rule_lines = lines.select do |line|
        parsed = JSON.parse(line)
        parsed["type"] == "Rule" && parsed["data"]["name"] == "Compound Rule"
      end

      assert rule_lines.any?

      rule_data = JSON.parse(rule_lines.first)
      conditions = rule_data["data"]["conditions"]

      assert_equal 1, conditions.length
      assert_equal "compound", conditions[0]["condition_type"]
      assert_equal "or", conditions[0]["operator"]
      assert_equal 2, conditions[0]["sub_conditions"].length
      assert_equal "walmart", conditions[0]["sub_conditions"][0]["value"]
      assert_equal "target", conditions[0]["sub_conditions"][1]["value"]
    end
  end

  test "only exports rules from the specified family" do
    # Create a rule for another family that should NOT be exported
    other_rule = @other_family.rules.build(
      name: "Other Family Rule",
      resource_type: "transaction",
      active: true
    )
    other_rule.conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "other"
    )
    other_rule.actions.build(
      action_type: "auto_categorize"
    )
    other_rule.save!

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      # Check rules.csv doesn't contain other family's data
      rules_csv = zip.read("rules.csv")
      assert rules_csv.include?(@rule.name)
      refute rules_csv.include?(other_rule.name)

      # Check NDJSON doesn't contain other family's rules
      ndjson_content = zip.read("all.ndjson")
      assert ndjson_content.include?(@rule.name)
      refute ndjson_content.include?(other_rule.name)
    end
  end
end
