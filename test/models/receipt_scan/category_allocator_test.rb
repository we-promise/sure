require "test_helper"

class ReceiptScan::CategoryAllocatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @food = categories(:food_and_drink)
    @household = @family.categories.create!(name: "Household", color: "#000000")
  end

  test "groups by category" do
    groups = allocate(total: "50.00", items: [
      item("Cheese", "20.00", "Food & Drink"),
      item("Soap", "20.00", "Household"),
      item("Bread", "10.00", "food & drink")
    ])

    assert_equal [ [ @food, BigDecimal("30.00") ], [ @household, BigDecimal("20.00") ] ], summary(groups)
    assert_equal [ "Cheese", "Bread" ], groups.first[:item_names]
  end

  test "folds small groups into the largest" do
    groups = allocate(total: "100.00", items: [
      item("Groceries", "99.01", "Food & Drink"),
      item("Bag", "0.99", "Household")
    ])

    assert_equal [ [ @food, BigDecimal("100.00") ] ], summary(groups)
    assert_equal [ "Groceries", "Bag" ], groups.first[:item_names]
  end

  test "distributes receipt discount proportionally" do
    groups = allocate(total: "90.00", items: [
      item("Cheese", "60.00", "Food & Drink"),
      item("Soap", "40.00", "Household")
    ])

    assert_equal [ [ @food, BigDecimal("54.00") ], [ @household, BigDecimal("36.00") ] ], summary(groups)
  end

  test "applies line discounts before grouping" do
    groups = allocate(total: "45.00", items: [
      item("Cheese", "30.00", "Food & Drink", discount: "5.00"),
      item("Soap", "20.00", "Household")
    ])

    assert_equal [ [ @food, BigDecimal("25.00") ], [ @household, BigDecimal("20.00") ] ], summary(groups)
  end

  test "remainder lands on largest" do
    groups = allocate(total: "10.00", items: [
      item("A", "3.33", "Food & Drink"),
      item("B", "3.33", "Household"),
      item("C", "3.33", nil)
    ])

    assert_equal BigDecimal("10.00"), groups.sum { _1[:amount] }
    assert_equal BigDecimal("3.34"), groups.first[:amount]
  end

  test "no line items" do
    groups = allocate(total: "12.50", items: [])

    assert_equal [ [ nil, BigDecimal("12.50") ] ], summary(groups)
  end

  test "unknown category" do
    groups = allocate(total: "30.00", items: [
      item("Cheese", "15.00", "Food & Drink"),
      item("Mystery", "15.00", "Not A Category")
    ])

    assert_equal [ @food, nil ].to_set, groups.map { _1[:category] }.to_set
  end

  test "items that net to zero fall back to one group with the total" do
    groups = allocate(total: "5.00", items: [ item("Free", "0", "Food & Drink") ])

    assert_equal [ [ nil, BigDecimal("5.00") ] ], summary(groups)
  end

  private
    def item(name, amount, category_name, discount: "0")
      { "name" => name, "quantity" => "1", "amount" => amount, "discount" => discount, "category_name" => category_name }
    end

    def allocate(total:, items:)
      extraction = build_receipt_extraction(total: BigDecimal(total), line_items: items)
      ReceiptScan::CategoryAllocator.new(extraction, categories: @family.categories).groups
    end

    def summary(groups)
      groups.map { [ _1[:category], _1[:amount] ] }
    end
end
