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

  test "can split a pending transaction" do
    @entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    assert @entry.transaction.pending?, "transaction should be pending"
    assert @entry.transaction.splittable?, "pending transactions should be splittable"

    children = @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    assert_equal 2, children.size
    assert @entry.reload.split_parent?
    assert @entry.transaction.pending?, "pending flag should still be set on the split parent"
  end

  test "split children inherit pending status from parent" do
    @entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    children = @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    children.each do |child|
      assert child.entryable.pending?, "split child should inherit parent's pending status"
      assert_equal({ "simplefin" => { "pending" => true } }, child.entryable.extra)
    end
  end

  test "split children of non-pending parent are not pending" do
    refute @entry.transaction.pending?, "parent should not be pending"

    children = @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    children.each do |child|
      refute child.entryable.pending?, "split child of non-pending parent should not be pending"
      assert_equal({}, child.entryable.extra)
    end
  end

  test "split children of pending parent are excluded from analytics via excluding_pending" do
    @entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    child_transaction_ids = @entry.child_entries.map(&:entryable_id)
    pending_children = Transaction.where(id: child_transaction_ids).excluding_pending

    assert_empty pending_children, "pending split children should be excluded by the excluding_pending scope"
  end

  test "split children inherit pending from plaid provider" do
    @entry.transaction.update!(extra: { "plaid" => { "pending" => true, "transaction_id" => "abc123" } })

    children = @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    children.each do |child|
      assert child.entryable.pending?, "split child should inherit plaid pending status"
      # Only the pending flag is copied, not provider-specific metadata like transaction_id
      assert_equal({ "plaid" => { "pending" => true } }, child.entryable.extra)
    end
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

  test "auto_exclude_stale_pending skips split-parent pending entries" do
    @entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    @entry.update!(date: 10.days.ago.to_date)

    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    @entry.reload

    # split parent is already excluded: true; auto_exclude must not count it as "newly excluded"
    excluded_count = Entry.auto_exclude_stale_pending(account: accounts(:depository), days: 8)

    assert_equal 0, excluded_count, "split-parent pending entries should not be auto-excluded"
    assert @entry.split_parent?, "split structure must be intact"
    assert_equal 2, @entry.child_entries.count
  end

  test "reconcile_pending_duplicates skips split-parent pending entries" do
    @entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })

    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    @entry.reload

    # Create a posted transaction that would otherwise match the pending split parent
    posted = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: accounts(:depository),
      date: Date.current
    )

    stats = Entry.reconcile_pending_duplicates(account: accounts(:depository))

    assert_equal 0, stats[:reconciled], "reconciler must skip split-parent pending entries"
    assert @entry.split_parent?, "split structure must remain intact"
    assert Entry.exists?(posted.id)
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

  test "excluding_split_children scope excludes split children but includes parent" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])
    @entry.reload

    child_ids = @entry.child_entries.pluck(:id)
    scope = Entry.excluding_split_children.where(account: accounts(:depository))

    assert_includes scope.pluck(:id), @entry.id, "split parent should be included"
    child_ids.each do |id|
      refute_includes scope.pluck(:id), id, "split child should be excluded"
    end
  end

  test "excluded non-split entry is not splittable" do
    @entry.update!(excluded: true)
    refute @entry.transaction.splittable?, "excluded non-split entry must not be splittable"
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
end
