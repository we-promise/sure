require "test_helper"

class Purchase::CategoryAllocatorTest < ActiveSupport::TestCase
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

  test "a refund keeps its categories, with small groups folded by size" do
    groups = allocate(total: "-100.00", items: [
      item("Cheese", "-60.00", "Food & Drink"),
      item("Soap", "-38.00", "Household"),
      item("Bag", "-2.00", nil)
    ])

    assert_equal [ [ @food, BigDecimal("-62.00") ], [ @household, BigDecimal("-38.00") ] ], summary(groups)
  end

  test "a refund read with positive lines is split in the total's sign" do
    groups = allocate(total: "-100.00", items: [
      item("Cheese", "60.00", "Food & Drink"),
      item("Soap", "38.00", "Household"),
      item("Bag", "2.00", nil)
    ])

    assert_equal [ [ @food, BigDecimal("-62.00") ], [ @household, BigDecimal("-38.00") ] ], summary(groups)
  end

  test "the rounding correction never leaves a negative group" do
    categories = Array.new(5) { |i| @family.categories.create!(name: "Cat #{i}", color: "#000000") }
    groups = allocate(total: "0.03", items: categories.map { item(_1.name, "0.01", _1.name) })

    assert groups.all? { _1[:amount] >= 0 }, groups.map { _1[:amount] }.inspect
    assert_equal BigDecimal("0.03"), groups.sum { _1[:amount] }
  end

  test "a currency with three decimals splits to the tenth of a cent" do
    groups = allocate(total: "1.001", precision: 3, items: [
      item("Cheese", "0.5005", "Food & Drink"),
      item("Soap", "0.5005", "Household")
    ])

    assert_equal BigDecimal("1.001"), groups.sum { _1[:amount] }
    assert_equal [ BigDecimal("0.501"), BigDecimal("0.500") ], groups.map { _1[:amount] }
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

  test "shipping in the total is spread across groups proportionally" do
    groups = allocate(total: "110.00", items: [
      item("Book", "60.00", "Food & Drink"),
      item("Pan", "40.00", "Household")
    ])

    assert_equal [ [ @food, BigDecimal("66.00") ], [ @household, BigDecimal("44.00") ] ], summary(groups)
    assert_equal BigDecimal("110.00"), groups.sum { _1[:amount] }
  end

  test "items without a discount key" do
    groups = allocate(total: "10.00", items: [ { "name" => "Pen", "amount" => "10.00", "category_name" => "Household" } ])

    assert_equal [ [ @household, BigDecimal("10.00") ] ], summary(groups)
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

    def allocate(total:, items:, precision: 2)
      Purchase::CategoryAllocator.new(total: BigDecimal(total), items:, categories: @family.categories, precision:).groups
    end

    def summary(groups)
      groups.map { [ _1[:category], _1[:amount] ] }
    end
end
