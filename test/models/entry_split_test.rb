require "test_helper"

class EntrySplitTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @entry = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: accounts(:depository),
      category: categories(:food_and_drink)
    )
  end

  test "split! creates child entries with correct amounts and marks parent excluded" do
    splits = [
      { name: "Groceries", amount: 70, category_id: categories(:food_and_drink).id },
      { name: "Household", amount: 30, category_id: nil }
    ]

    children = @entry.split!(splits)

    assert_equal 2, children.size
    assert_equal 70, children.first.amount
    assert_equal 30, children.last.amount
    assert @entry.reload.excluded?
    assert @entry.split_parent?
  end

  test "split! rejects when amounts don't sum to parent" do
    splits = [
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 30, category_id: nil }
    ]

    assert_raises(ActiveRecord::RecordInvalid) do
      @entry.split!(splits)
    end
  end

  test "split! allows mixed positive and negative amounts that sum to parent" do
    splits = [
      { name: "Main expense", amount: 130, category_id: nil },
      { name: "Refund", amount: -30, category_id: nil }
    ]

    children = @entry.split!(splits)

    assert_equal 2, children.size
    assert_equal 130, children.first.amount
    assert_equal(-30, children.last.amount)
  end

  test "cannot split transfers" do
    transfer = create_transfer(
      from_account: accounts(:depository),
      to_account: accounts(:credit_card),
      amount: 100
    )
    outflow_transaction = transfer.outflow_transaction

    refute outflow_transaction.splittable?
  end

  test "cannot split already-split parent" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    refute @entry.entryable.splittable?
  end

  test "cannot split child entry" do
    children = @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    refute children.first.entryable.splittable?
  end

  test "unsplit! removes children and restores parent" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    assert @entry.reload.excluded?
    assert_equal 2, @entry.child_entries.count

    @entry.unsplit!

    refute @entry.reload.excluded?
    assert_equal 0, @entry.child_entries.count
  end

  test "parent deletion cascades to children" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    child_ids = @entry.child_entries.pluck(:id)

    @entry.destroy!

    assert_empty Entry.where(id: child_ids)
  end

  test "individual child deletion is blocked" do
    children = @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    refute children.first.destroy
    assert children.first.persisted?
  end

  test "split parent cannot be un-excluded" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    @entry.reload
    @entry.excluded = false
    refute @entry.valid?
    assert_includes @entry.errors[:excluded], "cannot be toggled off for a split transaction"
  end

  test "excluding_split_parents scope excludes parents with children" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    scope = Entry.excluding_split_parents.where(account: accounts(:depository))
    refute_includes scope.pluck(:id), @entry.id
    assert_includes scope.pluck(:id), @entry.child_entries.first.id
  end

  test "children inherit parent's account, date, and currency" do
    children = @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    children.each do |child|
      assert_equal @entry.account_id, child.account_id
      assert_equal @entry.date, child.date
      assert_equal @entry.currency, child.currency
    end
  end

  test "split_parent? returns true when entry has children" do
    refute @entry.split_parent?

    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    assert @entry.split_parent?
  end

  test "split_child? returns true for child entries" do
    children = @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    assert children.first.split_child?
    refute @entry.split_child?
  end
end
