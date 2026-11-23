require "test_helper"

class Purchase::LinkerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @food = categories(:food_and_drink)
    @household = @family.categories.create!(name: "Household", color: "#000000")
    @shopping = @family.categories.create!(name: "Shopping", color: "#000000")
    @purchase = purchases(:allegro_awaiting)
    @purchase.update!(total: BigDecimal("100.00"), currency: "USD", ordered_on: Date.current - 2.days)
    @purchase.items.create!(name: "Coffee", amount: 60, category: @food, position: 0)
    @purchase.items.create!(name: "Soap", amount: 40, category: @household, position: 1)
    @entry = create_transaction(account: accounts(:depository), amount: 100, date: Date.current - 1.day, name: "Allegro")
  end

  test "links the transaction and records the purchase on it" do
    @purchase.link!(@entry)

    @purchase.reload
    assert_equal "matched", @purchase.status
    assert_equal @entry.entryable, @purchase.linked_transaction
    assert_not_nil @purchase.matched_at
    assert_equal({ "purchase_id" => @purchase.id, "merchant" => "Allegro", "order_number" => "A-1001" }, @entry.reload.entryable.extra["purchase"])
  end

  test "several category groups split the transaction" do
    @purchase.link!(@entry)

    children = @entry.reload.child_entries.order(:amount)
    assert_equal [ BigDecimal("40"), BigDecimal("60") ], children.map(&:amount)
    assert_equal [ @household, @food ], children.map { _1.entryable.category }
  end

  test "one category group sets and locks the category, overriding a rule's category" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @entry.entryable.enrich_attribute(:category_id, @shopping.id, source: "rule")

    @purchase.link!(@entry)

    transaction = @entry.reload.entryable
    assert_equal @food, transaction.category
    assert transaction.locked?(:category_id)
    assert_not @entry.split_parent?
  end

  test "a category the AI categorizer set and locked is replaced" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @entry.entryable.enrich_attribute(:category_id, @shopping.id, source: "ai")
    @entry.entryable.lock_attr!(:category_id)

    @purchase.link!(@entry)

    assert_equal @food, @entry.reload.entryable.category
  end

  test "a category the user changed after the AI set it is left alone" do
    @entry.entryable.enrich_attribute(:category_id, @food.id, source: "ai")
    @entry.entryable.lock_attr!(:category_id)
    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)

    @purchase.link!(@entry)

    assert_equal @shopping, @entry.reload.entryable.category
    assert_not @entry.split_parent?
  end

  test "a category set from an earlier link can be set again after unlinking" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @purchase.link!(@entry)
    @purchase.unlink!
    @purchase.update!(rejected_entry_ids: [])
    @purchase.items.update_all(category_id: @household.id)

    @purchase.link!(@entry.reload, manual: true)

    assert_equal @household, @entry.reload.entryable.category
  end

  test "a category the user set is left alone" do
    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)

    @purchase.link!(@entry)

    assert_equal @shopping, @entry.reload.entryable.category
    assert_not @entry.split_parent?
    assert_equal "matched", @purchase.reload.status
  end

  test "a category the user set is held back, and the order's categories can be applied on request" do
    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)
    @purchase.link!(@entry)
    assert @purchase.reload.categories_held_back?

    @purchase.apply_categories!(users(:family_admin))

    children = @entry.reload.child_entries.order(:amount)
    assert_equal [ @household, @food ], children.map { _1.entryable.category }
    assert_not @purchase.reload.categories_held_back?
  end

  test "applying one category replaces the user's and locks it" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)
    @purchase.link!(@entry)

    @purchase.apply_categories!(users(:family_admin))

    transaction = @entry.reload.entryable
    assert_equal @food, transaction.category
    assert transaction.locked?(:category_id)
    assert_not @purchase.reload.categories_held_back?
  end

  test "nothing is held back when the user's category already is the order's" do
    @purchase.items.where(name: "Soap").update_all(category_id: @food.id)
    @entry.entryable.update!(category: @food)
    @entry.entryable.lock_attr!(:category_id)

    @purchase.link!(@entry)

    assert_not @purchase.reload.categories_held_back?
  end

  test "nothing is held back once the order's categories were applied, or for an unlinked purchase" do
    assert_not @purchase.categories_held_back?

    @purchase.link!(@entry)

    assert_not @purchase.reload.categories_held_back?
  end

  test "applying categories needs a linked transaction the user can change" do
    assert_raises(Purchase::LinkError) { @purchase.apply_categories!(users(:family_admin)) }

    @entry.entryable.update!(category: @shopping)
    @entry.entryable.lock_attr!(:category_id)
    @purchase.link!(@entry)
    Account.stubs(:annotatable_by).returns(Account.none)

    assert_raises(Purchase::LinkError) { @purchase.apply_categories!(users(:family_member)) }
    assert_equal @shopping, @entry.reload.entryable.category
  end

  test "linking moves the receipt files onto the transaction and unlinking takes them off" do
    @purchase.receipt_files.attach(io: StringIO.new("jpeg"), filename: "receipt.jpg", content_type: "image/jpeg")

    @purchase.link!(@entry)
    assert_equal [ "receipt.jpg" ], @entry.entryable.reload.attachments.map { _1.filename.to_s }

    @purchase.unlink!
    assert_empty @entry.entryable.reload.attachments
    assert_equal 1, @purchase.reload.receipt_files.count
  end

  test "the owner sees the receipt only while they can open the linked transaction's account" do
    owner = @purchase.user
    @purchase.receipt_files.attach(io: StringIO.new("jpeg"), filename: "receipt.jpg", content_type: "image/jpeg")
    assert_equal 1, @purchase.receipt_documents_for(owner).size

    @purchase.link!(@entry)
    Account.any_instance.stubs(:shared_with?).returns(false)

    assert_empty @purchase.reload.receipt_documents_for(owner)
  end

  test "a released purchase takes its receipt off the transaction the bank's copy moved it to" do
    @purchase.receipt_files.attach(io: StringIO.new("jpeg"), filename: "receipt.jpg", content_type: "image/jpeg")
    @purchase.link!(@entry)
    posted = create_transaction(account: accounts(:depository), amount: 100, date: Date.current, name: "Allegro posted")
    posted.entryable.attachments.attach(@purchase.receipt_files.blobs)

    @purchase.release_transaction!

    assert_empty posted.entryable.reload.attachments
    assert_equal 1, @purchase.reload.receipt_files.count
  end

  test "receipt files that would exceed the transaction's attachment limit stay on the purchase" do
    Transaction::MAX_ATTACHMENTS_PER_TRANSACTION.times do |index|
      @entry.entryable.attachments.attach(io: StringIO.new("x#{index}"), filename: "f#{index}.pdf", content_type: "application/pdf")
    end
    @purchase.receipt_files.attach(io: StringIO.new("jpeg"), filename: "receipt.jpg", content_type: "image/jpeg")

    @purchase.link!(@entry)

    assert_equal "matched", @purchase.reload.status
    assert_equal Transaction::MAX_ATTACHMENTS_PER_TRANSACTION, @entry.entryable.reload.attachments.count
    assert_includes @purchase.review_reasons.map { _1["reason"] }, "too_many_attachments"
  end

  test "a purchase already linked to another transaction can't be linked again" do
    @purchase.link!(@entry)
    other = create_transaction(account: accounts(:depository), amount: 100, date: Date.current, name: "Allegro again")

    assert_raises(Purchase::LinkError) { @purchase.link!(other, manual: true) }
    assert_equal @entry.entryable, @purchase.reload.linked_transaction
    assert_nil other.entryable.reload.extra["purchase"]
  end

  test "an already split transaction is linked without changes" do
    @entry.split!([ { name: "A", amount: 50, category_id: nil }, { name: "B", amount: 50, category_id: nil } ])

    @purchase.link!(@entry)

    assert_equal [ BigDecimal("50"), BigDecimal("50") ], @entry.reload.child_entries.map(&:amount)
    assert_equal "matched", @purchase.reload.status
  end

  test "a manual link to a different amount links without categorizing and flags it" do
    other = create_transaction(account: accounts(:depository), amount: 120, date: Date.current, name: "Allegro")

    @purchase.link!(other, manual: true)

    assert_equal "matched", @purchase.reload.status
    assert_not other.reload.split_parent?
    assert_equal [ { "reason" => "amount_differs", "entry_id" => other.id } ], @purchase.review_reasons
  end

  test "linking an entry on an account the user cannot change raises" do
    @purchase.update!(user: users(:family_member))
    read_only = create_transaction(account: accounts(:credit_card), amount: 100, date: Date.current)

    assert_raises(Purchase::LinkError) { @purchase.link!(read_only, manual: true) }
    assert_nil @purchase.reload.transaction_id
  end

  test "linking an entry another purchase already has raises" do
    purchases(:allegro_matched).update!(linked_transaction: @entry.entryable)

    assert_raises(Purchase::LinkError) { @purchase.link!(@entry, manual: true) }
  end

  test "unlink reopens the purchase and remembers the entry" do
    @purchase.link!(@entry)

    @purchase.unlink!

    @purchase.reload
    assert_equal "awaiting_payment", @purchase.status
    assert_nil @purchase.transaction_id
    assert_equal [ @entry.id ], @purchase.rejected_entry_ids
    assert_nil @entry.reload.entryable.extra["purchase"]
  end

  test "dismiss stops matching" do
    @purchase.dismiss!

    assert_equal "dismissed", @purchase.reload.status
  end

  test "apply_match! records candidates when ambiguous and keeps an unmatched purchase unmatched" do
    second = create_transaction(account: accounts(:depository), amount: 100, date: Date.current, name: "Allegro")

    assert_equal :ambiguous, @purchase.apply_match!
    assert_equal "needs_matching", @purchase.reload.status
    assert_equal [ @entry.id, second.id ].sort, @purchase.match_candidate_entry_ids.sort

    @entry.destroy!
    second.destroy!
    @purchase.update!(status: :unmatched)
    assert_equal :none, @purchase.apply_match!
    assert_equal "unmatched", @purchase.reload.status
  end

  test "apply_match! moves a skipped purchase to unmatched" do
    @purchase.update!(payment_method: :installments)

    assert_equal :skipped, @purchase.apply_match!
    assert_equal "unmatched", @purchase.reload.status
  end
end
