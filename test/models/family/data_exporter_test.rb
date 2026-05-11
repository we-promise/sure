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
    expected_files = [ "accounts.csv", "transactions.csv", "trades.csv", "categories.csv", "rules.csv", "attachments.json", "all.ndjson" ]

    Zip::File.open_buffer(zip_data) do |zip|
      actual_files = zip.entries.map(&:name)
      assert_equal expected_files.sort, actual_files.sort
    end
  end

  test "exports attachment manifest metadata without binary payloads" do
    entry = @account.entries.create!(
      name: "Receipt Transaction",
      amount: 12.34,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )
    transaction = entry.transaction
    transaction.attachments.attach(
      io: StringIO.new("receipt bytes"),
      filename: "receipt.pdf",
      content_type: "application/pdf"
    )

    family_document = @family.family_documents.create!(
      filename: "statement.pdf",
      status: "ready"
    )
    family_document.file.attach(
      io: StringIO.new("statement bytes"),
      filename: "statement.pdf",
      content_type: "application/pdf"
    )

    other_account = @other_family.accounts.create!(
      name: "Other Attachment Account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
    other_entry = other_account.entries.create!(
      name: "Other Receipt",
      amount: 1,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )
    other_entry.transaction.attachments.attach(
      io: StringIO.new("other bytes"),
      filename: "other-receipt.pdf",
      content_type: "application/pdf"
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      manifest = JSON.parse(zip.read("attachments.json"))
      attachments = manifest["attachments"]
      filenames = attachments.map { |attachment| attachment["filename"] }

      assert_equal 1, manifest["version"]
      assert_equal false, manifest["binary_included"]
      assert_includes filenames, "receipt.pdf"
      assert_includes filenames, "statement.pdf"
      refute_includes filenames, "other-receipt.pdf"

      transaction_item = attachments.find { |attachment| attachment["record_type"] == "Transaction" }
      assert_equal transaction.id, transaction_item["record_id"]
      assert_equal entry.id, transaction_item["entry_id"]
      assert_equal @account.id, transaction_item["account_id"]
      assert_equal "attachments", transaction_item["name"]
      assert_equal "application/pdf", transaction_item["content_type"]
      assert_equal false, transaction_item["binary_included"]

      document_item = attachments.find { |attachment| attachment["record_type"] == "FamilyDocument" }
      assert_equal family_document.id, document_item["record_id"]
      assert_equal "ready", document_item["status"]
      assert_equal "file", document_item["name"]
      assert_equal false, document_item["binary_included"]
    end
  end

  test "exports split parent receipts in attachment manifest" do
    split_parent = create_transaction_entry(
      @account,
      amount: 60,
      date: Date.parse("2024-01-25"),
      name: "Split parent receipt"
    )
    split_parent.entryable.attachments.attach(
      io: StringIO.new("split parent receipt bytes"),
      filename: "split-parent-receipt.pdf",
      content_type: "application/pdf"
    )
    split_parent.split!([
      { name: "Split child", amount: 60, category_id: @category.id }
    ])

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      manifest = JSON.parse(zip.read("attachments.json"))
      attachment = manifest["attachments"].find { |item| item["filename"] == "split-parent-receipt.pdf" }

      assert attachment
      assert_equal "Transaction", attachment["record_type"]
      assert_equal split_parent.entryable.id, attachment["record_id"]
      assert_equal split_parent.id, attachment["entry_id"]
      assert_equal @account.id, attachment["account_id"]
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
      assert categories_csv.include?("name,color,parent_category,lucide_icon")

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

  test "exports valuation kind in NDJSON" do
    valuation_entry = @account.entries.create!(
      date: Date.parse("2020-04-01"),
      amount: 1000,
      name: "Opening balance",
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      valuation_lines = ndjson_content.split("\n").select do |line|
        JSON.parse(line)["type"] == "Valuation"
      end

      assert valuation_lines.any?

      valuation_data = valuation_lines
        .map { |line| JSON.parse(line) }
        .find { |line| line.dig("data", "entry_id") == valuation_entry.id }

      assert valuation_data
      assert_equal "opening_anchor", valuation_data["data"]["kind"]
    end
  end

  test "exports recurring transactions in NDJSON" do
    merchant = @family.merchants.create!(name: "Internet Provider")
    recurring_transaction = @family.recurring_transactions.create!(
      account: @account,
      merchant: merchant,
      amount: -89.99,
      currency: "USD",
      expected_day_of_month: 14,
      last_occurrence_date: Date.parse("2024-01-14"),
      next_expected_date: Date.parse("2024-02-14"),
      status: "active",
      occurrence_count: 6,
      manual: true,
      expected_amount_min: -95,
      expected_amount_max: -85,
      expected_amount_avg: -89.99
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_content = zip.read("all.ndjson")
      recurring_data = ndjson_content
        .split("\n")
        .map { |line| JSON.parse(line) }
        .find { |line| line["type"] == "RecurringTransaction" && line.dig("data", "id") == recurring_transaction.id }

      assert recurring_data
      assert_equal recurring_transaction.id, recurring_data["data"]["id"]
      assert_equal @account.id, recurring_data["data"]["account_id"]
      assert_equal merchant.id, recurring_data["data"]["merchant_id"]
      assert_equal "-89.99", BigDecimal(recurring_data["data"]["amount"].to_s).to_s("F")
      assert_equal "active", recurring_data["data"]["status"]
      assert_equal true, recurring_data["data"]["manual"]
      assert_not recurring_data["data"].key?("family_id")
    end
  end

  test "exports transfer decisions and rejected transfers in NDJSON" do
    destination_account = @family.accounts.create!(
      name: "Savings Account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )

    transfer_outflow = create_transaction_entry(@account, amount: 100, date: Date.parse("2024-01-15"), name: "Transfer to savings")
    transfer_inflow = create_transaction_entry(destination_account, amount: -100, date: Date.parse("2024-01-15"), name: "Transfer from checking")
    transfer = Transfer.create!(
      outflow_transaction: transfer_outflow.entryable,
      inflow_transaction: transfer_inflow.entryable,
      status: "confirmed",
      notes: "Confirmed by user"
    )

    rejected_outflow = create_transaction_entry(@account, amount: 25, date: Date.parse("2024-01-20"), name: "Candidate outflow")
    rejected_inflow = create_transaction_entry(destination_account, amount: -25, date: Date.parse("2024-01-20"), name: "Candidate inflow")
    rejected_transfer = RejectedTransfer.create!(
      outflow_transaction: rejected_outflow.entryable,
      inflow_transaction: rejected_inflow.entryable
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_records = zip.read("all.ndjson").split("\n").map { |line| JSON.parse(line) }

      transfer_data = ndjson_records.find { |record| record["type"] == "Transfer" && record.dig("data", "id") == transfer.id }
      assert transfer_data
      assert_equal transfer_inflow.entryable.id, transfer_data["data"]["inflow_transaction_id"]
      assert_equal transfer_outflow.entryable.id, transfer_data["data"]["outflow_transaction_id"]
      assert_equal "confirmed", transfer_data["data"]["status"]
      assert_equal "Confirmed by user", transfer_data["data"]["notes"]

      rejected_transfer_data = ndjson_records.find { |record| record["type"] == "RejectedTransfer" && record.dig("data", "id") == rejected_transfer.id }
      assert rejected_transfer_data
      assert_equal rejected_inflow.entryable.id, rejected_transfer_data["data"]["inflow_transaction_id"]
      assert_equal rejected_outflow.entryable.id, rejected_transfer_data["data"]["outflow_transaction_id"]

      # Transfer decisions must follow Transaction records so import can remap both sides.
      transaction_indices = ndjson_records.each_index.select { |index| ndjson_records[index]["type"] == "Transaction" }
      transfer_index = ndjson_records.index(transfer_data)
      rejected_transfer_index = ndjson_records.index(rejected_transfer_data)

      assert_operator transaction_indices.max, :<, transfer_index
      assert_operator transaction_indices.max, :<, rejected_transfer_index
    end
  end

  test "does not export transfer decisions for split parent transactions" do
    destination_account = @family.accounts.create!(
      name: "Split Transfer Savings",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )

    split_parent_outflow = create_transaction_entry(@account, amount: 60, date: Date.parse("2024-01-25"), name: "Split transfer parent")
    split_parent_outflow.split!([
      { name: "Split transfer child", amount: 60, category_id: @category.id }
    ])
    transfer_inflow = create_transaction_entry(destination_account, amount: -60, date: Date.parse("2024-01-25"), name: "Split transfer inflow")
    transfer = Transfer.create!(
      outflow_transaction: split_parent_outflow.entryable,
      inflow_transaction: transfer_inflow.entryable,
      status: "confirmed"
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_records = zip.read("all.ndjson").split("\n").map { |line| JSON.parse(line) }

      transaction_ids = ndjson_records
        .select { |record| record["type"] == "Transaction" }
        .map { |record| record.dig("data", "id") }
      transfer_ids = ndjson_records
        .select { |record| record["type"] == "Transfer" }
        .map { |record| record.dig("data", "id") }

      assert_not_includes transaction_ids, split_parent_outflow.entryable.id
      assert_not_includes transfer_ids, transfer.id
    end
  end

  test "exports balance history in NDJSON for backup verification" do
    balance = @account.balances.create!(
      date: Date.parse("2024-01-15"),
      balance: 1234.56,
      cash_balance: 1234.56,
      start_cash_balance: 1000,
      start_non_cash_balance: 0,
      cash_inflows: 234.56,
      cash_outflows: 0,
      flows_factor: 1,
      currency: "USD"
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_records = zip.read("all.ndjson").split("\n").map { |line| JSON.parse(line) }
      balance_data = ndjson_records.find { |record| record["type"] == "Balance" && record.dig("data", "id") == balance.id }

      assert balance_data
      assert_equal @account.id, balance_data["data"]["account_id"]
      assert_equal "2024-01-15", balance_data["data"]["date"]
      assert_equal "1234.56", BigDecimal(balance_data["data"]["balance"].to_s).to_s("F")
      assert_equal "USD", balance_data["data"]["currency"]
    end
  end

  test "exports balance history chronologically" do
    @account.balances.create!(date: Date.parse("2024-03-01"), balance: 300, flows_factor: 1, currency: "USD")
    @account.balances.create!(date: Date.parse("2024-01-01"), balance: 100, flows_factor: 1, currency: "USD")

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      balance_dates = zip.read("all.ndjson")
        .split("\n")
        .map { |line| JSON.parse(line) }
        .select { |record| record["type"] == "Balance" }
        .map { |record| Date.iso8601(record.dig("data", "date")) }

      assert_equal balance_dates.sort, balance_dates
    end
  end

  test "exports holding snapshots in NDJSON" do
    investment_account = @family.accounts.create!(
      name: "Investment Account",
      accountable: Investment.new,
      balance: 25_000,
      currency: "USD"
    )
    security = Security.create!(
      ticker: "VTI#{SecureRandom.hex(4).upcase}",
      name: "Vanguard Total Stock Market ETF",
      country_code: "US",
      exchange_operating_mic: "ARCX"
    )
    holding = investment_account.holdings.create!(
      security: security,
      date: Date.parse("2024-01-15"),
      qty: 100,
      price: 250.25,
      amount: 25_025,
      currency: "USD",
      cost_basis: 200,
      cost_basis_source: "manual",
      cost_basis_locked: true,
      security_locked: true
    )

    zip_data = @exporter.generate_export

    Zip::File.open_buffer(zip_data) do |zip|
      ndjson_records = zip.read("all.ndjson").split("\n").map { |line| JSON.parse(line) }
      holding_data = ndjson_records.find { |record| record["type"] == "Holding" && record.dig("data", "id") == holding.id }

      assert holding_data
      assert_equal investment_account.id, holding_data["data"]["account_id"]
      assert_equal security.id, holding_data["data"]["security_id"]
      assert_equal security.ticker, holding_data["data"]["ticker"]
      assert_equal "ARCX", holding_data["data"]["exchange_operating_mic"]
      assert_equal "2024-01-15", holding_data["data"]["date"]
      assert_equal "100.0", BigDecimal(holding_data["data"]["qty"].to_s).to_s("F")
      assert_equal "250.25", BigDecimal(holding_data["data"]["price"].to_s).to_s("F")
      assert_equal "25025.0", BigDecimal(holding_data["data"]["amount"].to_s).to_s("F")
      assert_equal "200.0", BigDecimal(holding_data["data"]["cost_basis"].to_s).to_s("F")
      assert_equal "manual", holding_data["data"]["cost_basis_source"]
      assert_equal true, holding_data["data"]["cost_basis_locked"]
      assert_not holding_data["data"].key?("created_at")
      assert_not holding_data["data"].key?("updated_at")
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

  private

    def create_transaction_entry(account, amount:, date:, name:)
      account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "funds_movement")
      )
    end
end
