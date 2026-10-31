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

  test "split! locks only the fields a split sets when asked to" do
    merchant = @entry.account.family.merchants.create!(name: "Lock merchant", type: "FamilyMerchant")
    splits = [
      { name: "Groceries", amount: 70, category_id: categories(:food_and_drink).id, merchant_id: merchant.id },
      { name: "Household", amount: 30, category_id: nil }
    ]

    locked, unlocked = @entry.split!(splits, lock_attributes: true).map(&:transaction)

    assert_equal %w[category_id merchant_id], locked.locked_attributes.keys.sort
    assert_empty unlocked.locked_attributes
  end

  test "split! locks nothing by default" do
    children = @entry.split!([
      { name: "Groceries", amount: 70, category_id: categories(:food_and_drink).id },
      { name: "Household", amount: 30, category_id: nil }
    ])

    assert children.all? { |child| child.transaction.locked_attributes.empty? }
  end

  test "split! supports a per-split merchant override, falling back to the parent's merchant" do
    parent_merchant = @entry.account.family.merchants.create!(name: "Parent merchant", type: "FamilyMerchant")
    split_merchant = @entry.account.family.merchants.create!(name: "Split merchant", type: "FamilyMerchant")
    @entry.transaction.update!(merchant: parent_merchant)

    splits = [
      { name: "Groceries", amount: 70, merchant_id: split_merchant.id },
      { name: "Household", amount: 30 }
    ]

    children = @entry.split!(splits)

    assert_equal split_merchant.id, children.first.transaction.merchant_id
    assert_equal parent_merchant.id, children.last.transaction.merchant_id
  end

  test "split! supports per-split tags" do
    tag_one = @entry.account.family.tags.create!(name: "Tag one")
    tag_two = @entry.account.family.tags.create!(name: "Tag two")

    splits = [
      { name: "Groceries", amount: 70, tag_ids: [ tag_one.id, tag_two.id ] },
      { name: "Household", amount: 30 }
    ]

    children = @entry.split!(splits)

    assert_equal [ tag_one, tag_two ].sort_by(&:id), children.first.transaction.tags.sort_by(&:id)
    assert_equal [], children.last.transaction.tags
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

  test "split! creates child entries with excluded: true when specified" do
    splits = [
      { name: "Part 1", amount: 50, category_id: nil, excluded: true },
      { name: "Part 2", amount: 50, category_id: nil, excluded: false }
    ]

    children = @entry.split!(splits)

    assert_equal 2, children.size
    assert children.first.excluded?
    refute children.last.excluded?
  end

  test "split! properly casts excluded from string values" do
    splits = [
      { name: "Part 1", amount: 50, category_id: nil, excluded: "true" },
      { name: "Part 2", amount: 50, category_id: nil, excluded: "false" }
    ]

    children = @entry.split!(splits)

    assert children.first.excluded?
    refute children.last.excluded?
  end

  test "excluded split children are excluded from balance calculations" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil, excluded: true },
      { name: "Part 2", amount: 50, category_id: nil, excluded: false }
    ])

    # Parent is always excluded for splits
    assert @entry.reload.excluded?

    # Excluded child should be filtered out by where(excluded: false)
    excluded_child = @entry.child_entries.find { |c| c.name == "Part 1" }
    non_excluded_child = @entry.child_entries.find { |c| c.name == "Part 2" }

    assert excluded_child.excluded?
    refute non_excluded_child.excluded?

    # where(excluded: false) should only include the non-excluded child
    visible_entries = Entry.where(id: @entry.child_entries.map(&:id)).where(excluded: false)
    assert_includes visible_entries.pluck(:id), non_excluded_child.id
    refute_includes visible_entries.pluck(:id), excluded_child.id
  end

  test "split_once! splits an entry that is not yet split" do
    assert @entry.split_once!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    assert_equal 2, @entry.reload.child_entries.count
  end

  test "split_once! skips an entry another caller split in the meantime" do
    stale = Entry.find(@entry.id)
    @entry.split!([ { name: "First", amount: 50 }, { name: "Run", amount: 50 } ])

    assert_not stale.split_once!([ { name: "Second", amount: 100 } ])
    assert_equal %w[First Run], @entry.reload.child_entries.order(:name).pluck(:name)
  end

  test "split_once! skips an entry excluded in the meantime" do
    stale = Entry.find(@entry.id)
    Entry.where(id: @entry.id).update_all(excluded: true)

    assert_not stale.split_once!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    assert_not @entry.reload.split_parent?
  end

  test "split_once! skips a transaction that became pending in the meantime" do
    stale = Entry.find(@entry.id)
    Transaction.where(id: @entry.entryable_id).update_all(extra: { "plaid" => { "pending" => true } })
    assert Transaction.find(@entry.entryable_id).pending?, "fixture must read as pending"

    assert_not stale.split_once!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    assert_not @entry.reload.split_parent?
  end

  test "split_once! skips a transaction that became a transfer in the meantime" do
    stale = Entry.find(@entry.id)
    Transaction.where(id: @entry.entryable_id).update_all(kind: "funds_movement")
    assert Transaction.find(@entry.entryable_id).transfer?, "fixture must read as a transfer"

    assert_not stale.split_once!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    assert_not @entry.reload.split_parent?
  end

  test "resplit! replaces the children of a split" do
    @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])

    assert @entry.resplit!([ { name: "C", amount: 30 }, { name: "D", amount: 70 } ])
    assert_equal %w[C D], @entry.reload.child_entries.order(:name).pluck(:name)
    assert @entry.excluded?
  end

  test "resplit! does not resurrect a split another caller removed" do
    @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    stale = Entry.find(@entry.id)
    @entry.unsplit!

    assert_not stale.resplit!([ { name: "C", amount: 30 }, { name: "D", amount: 70 } ])
    assert_not @entry.reload.split_parent?
    assert_not @entry.excluded?
  end

  test "unsplit_once! unsplits once and then reports nothing to do" do
    @entry.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])
    stale = Entry.find(@entry.id)

    assert @entry.unsplit_once!
    assert_not stale.unsplit_once!
    assert_not @entry.reload.split_parent?
  end
end
