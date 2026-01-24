require "test_helper"

class Family::DataImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "imports accounts with accountable data" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "old-account-1",
          name: "Test Checking",
          balance: "1500.00",
          currency: "USD",
          accountable_type: "Depository",
          accountable: { subtype: "checking" }
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
    account = result[:accounts].first
    assert_equal "Test Checking", account.name
    assert_equal 1500.0, account.balance.to_f
    assert_equal "USD", account.currency
    assert_equal "Depository", account.accountable_type
  end

  test "imports categories with parent relationships" do
    ndjson = build_ndjson([
      {
        type: "Category",
        data: {
          id: "cat-parent",
          name: "Shopping",
          color: "#FF5733",
          classification: "expense"
        }
      },
      {
        type: "Category",
        data: {
          id: "cat-child",
          name: "Groceries",
          color: "#33FF57",
          classification: "expense",
          parent_id: "cat-parent"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    parent = @family.categories.find_by(name: "Shopping")
    child = @family.categories.find_by(name: "Groceries")

    assert_not_nil parent
    assert_not_nil child
    assert_equal parent.id, child.parent_id
  end

  test "imports tags" do
    ndjson = build_ndjson([
      {
        type: "Tag",
        data: {
          id: "tag-1",
          name: "Important",
          color: "#FF0000"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    tag = @family.tags.find_by(name: "Important")
    assert_not_nil tag
    assert_equal "#FF0000", tag.color
  end

  test "imports merchants" do
    ndjson = build_ndjson([
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Amazon"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    merchant = @family.merchants.find_by(name: "Amazon")
    assert_not_nil merchant
  end

  test "imports transactions with references" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "acct-1",
          name: "Main Account",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      {
        type: "Category",
        data: {
          id: "cat-1",
          name: "Food",
          color: "#FF0000",
          classification: "expense"
        }
      },
      {
        type: "Tag",
        data: {
          id: "tag-1",
          name: "Essential"
        }
      },
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-1",
          date: "2024-01-15",
          amount: "-50.00",
          name: "Grocery Store",
          currency: "USD",
          category_id: "cat-1",
          tag_ids: [ "tag-1" ],
          notes: "Weekly groceries"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:entries].count

    transaction = @family.transactions.first
    assert_not_nil transaction
    assert_equal "Grocery Store", transaction.entry.name
    assert_equal -50.0, transaction.entry.amount.to_f
    assert_equal "Food", transaction.category.name
    assert_equal 1, transaction.tags.count
    assert_equal "Essential", transaction.tags.first.name
    assert_equal "Weekly groceries", transaction.entry.notes
  end

  test "imports trades with securities" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "inv-acct-1",
          name: "Investment Account",
          balance: "10000",
          currency: "USD",
          accountable_type: "Investment"
        }
      },
      {
        type: "Trade",
        data: {
          id: "trade-1",
          account_id: "inv-acct-1",
          date: "2024-01-15",
          ticker: "AAPL",
          qty: "10",
          price: "150.00",
          amount: "-1500.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    # Account + Opening balance + Trade entry
    assert_equal 1, result[:entries].count

    trade = @family.trades.first
    assert_not_nil trade
    assert_equal "AAPL", trade.security.ticker
    assert_equal 10.0, trade.qty.to_f
    assert_equal 150.0, trade.price.to_f
  end

  test "imports valuations" do
    ndjson = build_ndjson([
      {
        type: "Account",
        data: {
          id: "prop-acct-1",
          name: "Property",
          balance: "500000",
          currency: "USD",
          accountable_type: "Property"
        }
      },
      {
        type: "Valuation",
        data: {
          id: "val-1",
          account_id: "prop-acct-1",
          date: "2024-06-15",
          amount: "520000",
          name: "Updated valuation",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:entries].count

    account = @family.accounts.find_by(name: "Property")
    valuation = account.valuations.find_by(entry: { name: "Updated valuation" })
    assert_not_nil valuation
    assert_equal 520000.0, valuation.entry.amount.to_f
  end

  test "imports budgets" do
    ndjson = build_ndjson([
      {
        type: "Budget",
        data: {
          id: "budget-1",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "3000.00",
          expected_income: "5000.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    budget = @family.budgets.first
    assert_not_nil budget
    assert_equal Date.parse("2024-01-01"), budget.start_date
    assert_equal Date.parse("2024-01-31"), budget.end_date
    assert_equal 3000.0, budget.budgeted_spending.to_f
    assert_equal 5000.0, budget.expected_income.to_f
  end

  test "imports budget_categories" do
    ndjson = build_ndjson([
      {
        type: "Category",
        data: {
          id: "cat-groceries",
          name: "Groceries",
          color: "#00FF00",
          classification: "expense"
        }
      },
      {
        type: "Budget",
        data: {
          id: "budget-1",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "3000.00",
          expected_income: "5000.00",
          currency: "USD"
        }
      },
      {
        type: "BudgetCategory",
        data: {
          id: "bc-1",
          budget_id: "budget-1",
          category_id: "cat-groceries",
          budgeted_spending: "500.00",
          currency: "USD"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    budget = @family.budgets.first
    budget_category = budget.budget_categories.first
    assert_not_nil budget_category
    assert_equal "Groceries", budget_category.category.name
    assert_equal 500.0, budget_category.budgeted_spending.to_f
  end

  test "imports rules with conditions and actions" do
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Categorize Coffee",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "transaction_name",
              operator: "like",
              value: "starbucks"
            }
          ],
          actions: [
            {
              action_type: "set_transaction_category",
              value: "Coffee"
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by(name: "Categorize Coffee")
    assert_not_nil rule
    assert rule.active
    assert_equal "transaction", rule.resource_type

    assert_equal 1, rule.conditions.count
    condition = rule.conditions.first
    assert_equal "transaction_name", condition.condition_type
    assert_equal "like", condition.operator
    assert_equal "starbucks", condition.value

    assert_equal 1, rule.actions.count
    action = rule.actions.first
    assert_equal "set_transaction_category", action.action_type

    # Category should be created
    category = @family.categories.find_by(name: "Coffee")
    assert_not_nil category
    assert_equal category.id, action.value
  end

  test "imports rules with compound conditions" do
    ndjson = build_ndjson([
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Compound Rule",
          resource_type: "transaction",
          active: true,
          conditions: [
            {
              condition_type: "compound",
              operator: "or",
              sub_conditions: [
                {
                  condition_type: "transaction_name",
                  operator: "like",
                  value: "walmart"
                },
                {
                  condition_type: "transaction_name",
                  operator: "like",
                  value: "target"
                }
              ]
            }
          ],
          actions: [
            {
              action_type: "auto_categorize"
            }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    importer.import!

    rule = @family.rules.find_by(name: "Compound Rule")
    assert_not_nil rule

    parent_condition = rule.conditions.first
    assert_equal "compound", parent_condition.condition_type
    assert_equal "or", parent_condition.operator
    assert_equal 2, parent_condition.sub_conditions.count
  end

  test "skips invalid records gracefully" do
    ndjson = "not valid json\n" + build_ndjson([
      {
        type: "Account",
        data: {
          id: "valid-acct",
          name: "Valid Account",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
    assert_equal "Valid Account", result[:accounts].first.name
  end

  test "skips unsupported record types" do
    ndjson = build_ndjson([
      {
        type: "UnsupportedType",
        data: { id: "unknown" }
      },
      {
        type: "Account",
        data: {
          id: "valid-acct",
          name: "Known Account",
          balance: "1000",
          currency: "USD",
          accountable_type: "Depository"
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    assert_equal 1, result[:accounts].count
  end

  test "full import scenario with all entity types" do
    ndjson = build_ndjson([
      # Account
      {
        type: "Account",
        data: {
          id: "acct-main",
          name: "Main Checking",
          balance: "5000",
          currency: "USD",
          accountable_type: "Depository"
        }
      },
      # Category
      {
        type: "Category",
        data: {
          id: "cat-food",
          name: "Food",
          color: "#FF5733",
          classification: "expense"
        }
      },
      # Tag
      {
        type: "Tag",
        data: {
          id: "tag-weekly",
          name: "Weekly"
        }
      },
      # Merchant
      {
        type: "Merchant",
        data: {
          id: "merchant-1",
          name: "Local Grocery"
        }
      },
      # Transaction
      {
        type: "Transaction",
        data: {
          id: "txn-1",
          account_id: "acct-main",
          date: "2024-01-15",
          amount: "-75.50",
          name: "Weekly groceries",
          currency: "USD",
          category_id: "cat-food",
          merchant_id: "merchant-1",
          tag_ids: [ "tag-weekly" ]
        }
      },
      # Budget
      {
        type: "Budget",
        data: {
          id: "budget-jan",
          start_date: "2024-01-01",
          end_date: "2024-01-31",
          budgeted_spending: "2000",
          expected_income: "4000",
          currency: "USD"
        }
      },
      # BudgetCategory
      {
        type: "BudgetCategory",
        data: {
          id: "bc-food",
          budget_id: "budget-jan",
          category_id: "cat-food",
          budgeted_spending: "500",
          currency: "USD"
        }
      },
      # Rule
      {
        type: "Rule",
        version: 1,
        data: {
          name: "Auto-tag groceries",
          resource_type: "transaction",
          active: true,
          conditions: [
            { condition_type: "transaction_name", operator: "like", value: "grocery" }
          ],
          actions: [
            { action_type: "set_transaction_tags", value: "Weekly" }
          ]
        }
      }
    ])

    importer = Family::DataImporter.new(@family, ndjson)
    result = importer.import!

    # Verify all entities were created
    assert_equal 1, result[:accounts].count
    assert_equal 1, @family.categories.count
    assert_equal 1, @family.tags.count
    assert_equal 1, @family.merchants.count
    assert_equal 1, @family.transactions.count
    assert_equal 1, @family.budgets.count
    assert_equal 1, @family.budget_categories.count
    assert_equal 1, @family.rules.count

    # Verify relationships
    transaction = @family.transactions.first
    assert_equal "Food", transaction.category.name
    assert_equal "Local Grocery", transaction.merchant.name
    assert_equal "Weekly", transaction.tags.first.name
  end

  private

  def build_ndjson(records)
    records.map(&:to_json).join("\n")
  end
end
