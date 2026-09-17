require "test_helper"

class PocketTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository) # balance: 5000 USD
    @pocket = pockets(:emergency_fund) # allocated: 1000 USD, no tag
    @tagged_pocket = pockets(:vacation)  # allocated: 500 USD, tag: one
  end

  test "valid pocket saves" do
    pocket = @account.pockets.new(name: "Savings", allocated_amount: 100, currency: "USD")
    assert pocket.valid?
  end

  test "requires name" do
    pocket = @account.pockets.new(allocated_amount: 100, currency: "USD")
    assert_not pocket.valid?
    assert_includes pocket.errors[:name], I18n.t("errors.messages.blank")
  end

  test "allocated_amount must be non-negative" do
    pocket = @account.pockets.new(name: "Bad", allocated_amount: -1, currency: "USD")
    assert_not pocket.valid?
    assert pocket.errors[:allocated_amount].any?
  end

  test "pocket can be zero" do
    pocket = @account.pockets.new(name: "Empty", allocated_amount: 0, currency: "USD")
    assert pocket.valid?
  end

  test "total pockets cannot exceed account balance on create" do
    # account balance is 5000, existing pockets sum to 1500 (1000 + 500)
    # adding 3600 would push total to 5100 > 5000
    pocket = @account.pockets.new(name: "Too big", allocated_amount: 3600, currency: "USD")
    assert_not pocket.valid?
    assert pocket.errors[:allocated_amount].any?
  end

  test "total pockets at exactly account balance is valid" do
    # existing pockets sum to 1500, account balance is 5000 → max new = 3500
    pocket = @account.pockets.new(name: "Max", allocated_amount: 3500, currency: "USD")
    assert pocket.valid?
  end

  test "updating a pocket recalculates correctly excluding self" do
    # emergency_fund is 1000; vacation is 500 → total 1500 allocated
    # increasing emergency_fund to 4500 would still be within 5000
    @pocket.allocated_amount = 4500
    assert @pocket.valid?
  end

  test "tag_id must be unique per account" do
    pocket = @account.pockets.new(name: "Dupe", allocated_amount: 100, currency: "USD", tag: tags(:one))
    assert_not pocket.valid?
    assert pocket.errors[:tag_id].any?
  end

  # Account#free_balance and Account#pockets_overflow?

  test "free_balance equals balance minus sum of pockets" do
    # 5000 - (1000 + 500) = 3500
    assert_equal 3500, @account.free_balance
  end

  test "pockets_overflow? is false when pockets are within balance" do
    assert_not @account.pockets_overflow?
  end

  test "pockets_overflow? is true when account balance drops below pockets total" do
    @account.update_column(:balance, 1000)
    assert @account.pockets_overflow?
  end

  # Auto-fill via Tagging

  test "creating a tagging fills linked pocket" do
    # Fresh tag/pocket so this doesn't collide with the fixture tagging already
    # linking tags(:one) to transactions(:one) (recompute_from_tag! would
    # otherwise pull that pre-existing contribution into the total).
    fresh_tag = @account.family.tags.create!(name: "Fill Tag")
    pocket = @account.pockets.create!(name: "Fill Pocket", allocated_amount: 0, currency: "USD",
                                      tag: fresh_tag, fill_direction: "both")

    # Use a fresh income entry (amount < 0 in DB) so income fills the pocket
    entry = Entry.create!(account: @account, entryable: Transaction.new,
      date: 1.day.ago.to_date, name: "Fresh income", amount: -10, currency: "USD")

    assert_difference "pocket.reload.allocated_amount", entry.amount.abs do
      Tagging.create!(tag: fresh_tag, taggable: entry.entryable)
    end
  end

  test "destroying a tagging unfills linked pocket" do
    fresh_tag = @account.family.tags.create!(name: "Unfill Tag")
    pocket = @account.pockets.create!(name: "Unfill Pocket", allocated_amount: 0, currency: "USD",
                                      tag: fresh_tag, fill_direction: "both")

    entry = Entry.create!(account: @account, entryable: Transaction.new,
      date: 1.day.ago.to_date, name: "Fresh income", amount: -10, currency: "USD")
    tagging = Tagging.create!(tag: fresh_tag, taggable: entry.entryable)

    assert_difference "pocket.reload.allocated_amount", -entry.amount.abs do
      tagging.destroy!
    end
  end

  # Regression: transaction.tag_ids= is the path actually used by the edit
  # form, bulk update, rules, and the API to add/remove tags. Unlike
  # Tagging.create!/destroy! above, removing an id from a has_many :through
  # collection without dependent: :destroy issues a raw DELETE that skips
  # Tagging#after_destroy, so the pocket amount never reverses.
  test "removing a tag via tag_ids= unfills linked pocket" do
    fresh_tag = @account.family.tags.create!(name: "Tag Ids Unfill Tag")
    pocket = @account.pockets.create!(name: "Tag Ids Unfill Pocket", allocated_amount: 0, currency: "USD",
                                      tag: fresh_tag, fill_direction: "both")

    entry = Entry.create!(account: @account, entryable: Transaction.new,
      date: 1.day.ago.to_date, name: "Fresh income", amount: -10, currency: "USD")
    entry.entryable.tag_ids = [ fresh_tag.id ]
    assert_equal 10, pocket.reload.allocated_amount

    assert_difference "pocket.reload.allocated_amount", -10 do
      entry.entryable.tag_ids = []
    end
  end

  test "tagging with unlinked tag does not affect any pocket" do
    # Fresh entry — transactions(:one) is already tagged with tags(:two) via
    # fixtures, and the new taggings unique index rejects a literal duplicate.
    entry = Entry.create!(account: @account, entryable: Transaction.new,
      date: 1.day.ago.to_date, name: "Unlinked", amount: -25, currency: "USD")

    assert_no_difference "@pocket.reload.allocated_amount" do
      Tagging.create!(tag: tags(:two), taggable: entry.entryable)
    end
  end

  test "duplicate tagging for the same tag and transaction is rejected" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      Tagging.create!(tag: tags(:one), taggable: transactions(:one))
    end
  end

  # Retroactive sync when tag is assigned

  test "linking a tag to a pocket retroactively sums existing tagged transactions" do
    # Use a fresh account and tag with known transactions so we control the data
    fresh_account = create_depository_account("Retro Account")
    fresh_tag = families(:dylan_family).tags.create!(name: "RetroTag")

    # Create two deposit transactions (negative = money coming in) and tag them
    [ -100, -200 ].each do |amount|
      entry = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "deposit", amount: amount, currency: "USD")
      Tagging.create!(tag: fresh_tag, taggable: entry.entryable)
    end

    pocket = fresh_account.pockets.create!(name: "Retro Pocket", allocated_amount: 0, currency: "USD")

    assert_changes "pocket.reload.allocated_amount", from: 0, to: 300 do
      pocket.update!(tag: fresh_tag)
    end
  end

  test "changing tag subtracts old contribution and adds new tag sum" do
    # Build a controlled scenario: a fresh account with known tagged transactions
    fresh_account = create_depository_account("Change Tag Account")
    tag_a = families(:dylan_family).tags.create!(name: "TagA")
    tag_b = families(:dylan_family).tags.create!(name: "TagB")

    # 2 deposit transactions tagged with tag_a (sum = 150)
    [ -100, -50 ].each do |amount|
      entry = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "deposit_a", amount: amount, currency: "USD")
      Tagging.create!(tag: tag_a, taggable: entry.entryable)
    end

    # 1 deposit transaction tagged with tag_b (sum = 75)
    entry_b = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "deposit_b", amount: -75, currency: "USD")
    Tagging.create!(tag: tag_b, taggable: entry_b.entryable)

    # Create pocket linked to tag_a → starts at 150
    pocket = fresh_account.pockets.create!(name: "Switch Pocket", allocated_amount: 0, currency: "USD",
                                           tag: tag_a)
    assert_equal 150, pocket.reload.allocated_amount

    # Switch to tag_b: remove 150 (old), add 75 (new) → 75
    pocket.update!(tag: tag_b)
    assert_equal 75, pocket.reload.allocated_amount
  end

  test "removing a tag clears the tag contribution from allocated amount" do
    fresh_account = create_depository_account("Remove Tag Account")
    fresh_tag = families(:dylan_family).tags.create!(name: "RemoveTag")
    entry = Entry.create!(account: fresh_account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "deposit", amount: -80, currency: "USD")
    Tagging.create!(tag: fresh_tag, taggable: entry.entryable)

    pocket = fresh_account.pockets.create!(name: "Detach Pocket", allocated_amount: 0, currency: "USD",
                                           tag: fresh_tag)
    assert_equal 80, pocket.reload.allocated_amount

    pocket.update!(tag: nil)
    assert_equal 0, pocket.reload.allocated_amount
  end

  # fill_direction filtering

  test "inflows direction only counts negative amounts" do
    fresh_account = create_depository_account("Dir Account")
    tag = families(:dylan_family).tags.create!(name: "DirTag")

    deposit = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "deposit", amount: -200, currency: "USD")
    expense = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "expense", amount: 50, currency: "USD")
    Tagging.create!(tag: tag, taggable: deposit.entryable)
    Tagging.create!(tag: tag, taggable: expense.entryable)

    pocket = fresh_account.pockets.create!(name: "Dir Pocket", allocated_amount: 0, currency: "USD",
                                           tag: tag, fill_direction: :inflows)
    assert_equal 200, pocket.reload.allocated_amount
  end

  test "outflows direction only counts positive amounts" do
    fresh_account = create_depository_account("Out Account")
    tag = families(:dylan_family).tags.create!(name: "OutTag")

    deposit = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "deposit", amount: -200, currency: "USD")
    expense = Entry.create!(account: fresh_account, entryable: Transaction.new,
                            date: 1.day.ago.to_date, name: "expense", amount: 50, currency: "USD")
    Tagging.create!(tag: tag, taggable: deposit.entryable)
    Tagging.create!(tag: tag, taggable: expense.entryable)

    pocket = fresh_account.pockets.create!(name: "Out Pocket", allocated_amount: 0, currency: "USD",
                                           tag: tag, fill_direction: :outflows)
    assert_equal 50, pocket.reload.allocated_amount
  end

  test "changing fill_direction triggers recompute" do
    fresh_account = create_depository_account("Recomp Account")
    tag = families(:dylan_family).tags.create!(name: "RecompTag")
    Entry.create!(account: fresh_account, entryable: Transaction.new,
                  date: 1.day.ago.to_date, name: "deposit", amount: -300, currency: "USD").tap do |e|
      Tagging.create!(tag: tag, taggable: e.entryable)
    end
    Entry.create!(account: fresh_account, entryable: Transaction.new,
                  date: 1.day.ago.to_date, name: "expense", amount: 100, currency: "USD").tap do |e|
      Tagging.create!(tag: tag, taggable: e.entryable)
    end

    pocket = fresh_account.pockets.create!(name: "Recomp Pocket", allocated_amount: 0, currency: "USD",
                                           tag: tag, fill_direction: :inflows)
    assert_equal 300, pocket.reload.allocated_amount

    pocket.update!(fill_direction: :both)
    assert_equal 200, pocket.reload.allocated_amount  # 300 income - 100 expense = 200
  end

  # allocation_percent

  test "allocation_percent returns correct percentage" do
    assert_equal 20, @pocket.allocation_percent(5000)
  end

  test "allocation_percent is capped at 100 even when overallocated" do
    @pocket.allocated_amount = 9999
    assert_equal 100, @pocket.allocation_percent(100)
  end

  test "allocation_percent returns 0 when balance is zero" do
    assert_equal 0, @pocket.allocation_percent(0)
  end

  test "allocation_percent returns 0 when balance is nil" do
    assert_equal 0, @pocket.allocation_percent(nil)
  end

  # Validations

  test "account must be a depository" do
    pocket = accounts(:credit_card).pockets.new(name: "Bad", allocated_amount: 0, currency: "USD")
    assert_not pocket.valid?
    assert pocket.errors[:account].any?
  end

  test "tag must belong to the same family as the account" do
    other_family_tag = families(:empty).tags.create!(name: "Other")
    pocket = @account.pockets.new(name: "Bad tag", allocated_amount: 0, currency: "USD", tag: other_family_tag)
    assert_not pocket.valid?
    assert pocket.errors[:tag].any?
  end

  # Currency isolation

  test "tagging an entry with a different currency does not affect pocket" do
    entry = Entry.create!(account: @account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "EUR deposit", amount: -50, currency: "EUR")

    assert_no_difference "@tagged_pocket.reload.allocated_amount" do
      Tagging.create!(tag: tags(:one), taggable: entry.entryable)
    end
  end

  # apply_tagging / reverse_tagging in :both mode (vacation pocket)

  test "both direction increments pocket on income" do
    fresh_tag = @account.family.tags.create!(name: "Both Income Tag")
    pocket = @account.pockets.create!(name: "Both Income Pocket", allocated_amount: 0, currency: "USD",
                                      tag: fresh_tag, fill_direction: "both")

    entry = Entry.create!(account: @account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "income", amount: -100, currency: "USD")

    assert_difference "pocket.reload.allocated_amount", 100 do
      Tagging.create!(tag: fresh_tag, taggable: entry.entryable)
    end
  end

  test "both direction decrements pocket on expense" do
    fresh_tag = @account.family.tags.create!(name: "Both Expense Tag")
    pocket = @account.pockets.create!(name: "Both Expense Pocket", allocated_amount: 0, currency: "USD",
                                      tag: fresh_tag, fill_direction: "both")

    seed_entry = Entry.create!(account: @account, entryable: Transaction.new,
                          date: 2.days.ago.to_date, name: "seed income", amount: -200, currency: "USD")
    Tagging.create!(tag: fresh_tag, taggable: seed_entry.entryable)
    assert_equal 200, pocket.reload.allocated_amount

    entry = Entry.create!(account: @account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "expense", amount: 60, currency: "USD")

    assert_difference "pocket.reload.allocated_amount", -60 do
      Tagging.create!(tag: fresh_tag, taggable: entry.entryable)
    end
  end

  # recompute_from_tag!

  test "recompute_from_tag! sets allocated_amount from current tagged transactions" do
    fresh_account = create_depository_account("Recompute Account")
    fresh_tag = families(:dylan_family).tags.create!(name: "RecomputeTag")
    entry = Entry.create!(account: fresh_account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "salary", amount: -400, currency: "USD")
    Tagging.create!(tag: fresh_tag, taggable: entry.entryable)

    pocket = fresh_account.pockets.create!(name: "Recompute Pocket", allocated_amount: 0, currency: "USD",
                                           tag: fresh_tag)
    pocket.update_column(:allocated_amount, 0)
    pocket.recompute_from_tag!

    assert_equal 400, pocket.reload.allocated_amount
  end

  test "destroying an entry via AR decrements the linked pocket" do
    fresh_account = create_depository_account("Destroy Chain Account")
    fresh_tag = families(:dylan_family).tags.create!(name: "DestroyChainTag")
    entry = Entry.create!(account: fresh_account, entryable: Transaction.new,
                          date: 1.day.ago.to_date, name: "salary", amount: -300, currency: "USD")
    Tagging.create!(tag: fresh_tag, taggable: entry.entryable)

    pocket = fresh_account.pockets.create!(name: "Destroy Pocket", allocated_amount: 0, currency: "USD",
                                           tag: fresh_tag)
    assert_equal 300, pocket.reload.allocated_amount

    assert_difference "pocket.reload.allocated_amount", -300 do
      entry.destroy!
    end
  end

  test "recompute_from_tag! is a no-op when pocket has no tag" do
    @pocket.update_column(:allocated_amount, 999)
    @pocket.recompute_from_tag!
    assert_equal 999, @pocket.reload.allocated_amount
  end

  private

    def create_depository_account(name)
      Account.create!(
        family: families(:dylan_family),
        owner: users(:family_admin),
        accountable: Depository.new,
        name: name,
        balance: 5000,
        currency: "USD",
        status: "active"
      )
    end
end
