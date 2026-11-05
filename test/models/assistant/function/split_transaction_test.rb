require "test_helper"

class Assistant::Function::SplitTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @entry = create_transaction(account: accounts(:depository), amount: 590, name: "Rent")
    @transaction = @entry.entryable
    @function = Assistant::Function::SplitTransaction.new(@user)
  end

  test "splits into parts that sum to the original and excludes the parent" do
    category = categories(:food_and_drink)

    result = @function.call(
      "id" => @transaction.id,
      "splits" => [
        { "name" => "My rent", "amount" => "295", "category_id" => category.id },
        { "name" => "Flatmate's rent", "amount" => "295", "excluded" => true }
      ]
    )

    assert_equal true, result[:success], result[:message]
    assert_equal 2, result[:transaction][:children].size

    @entry.reload
    assert @entry.split_parent?
    assert @entry.excluded?
    assert_equal 590, @entry.child_entries.sum(:amount)

    mine, flatmate = @entry.child_entries.order(:created_at).to_a
    assert_equal category, mine.entryable.category
    assert_not mine.excluded?
    assert flatmate.excluded?
  end

  test "gives each part its own merchant and tags" do
    merchant = merchants(:amazon)
    tag = tags(:one)

    result = @function.call(
      "id" => @transaction.id,
      "splits" => [
        { "amount" => "295", "merchant_id" => merchant.id, "tag_ids" => [ tag.id ] },
        { "amount" => "295" }
      ]
    )

    assert_equal true, result[:success], result[:message]
    first, second = @entry.reload.child_entries.order(:created_at).map(&:entryable)
    assert_equal merchant, first.merchant
    assert_equal [ tag ], first.tags.to_a
    assert_empty second.tags
  end

  test "splits income using positive amounts like get_transactions returns" do
    income = create_transaction(account: accounts(:depository), amount: -200, name: "Refund")

    result = @function.call(
      "id" => income.entryable_id,
      "splits" => [ { "amount" => "150" }, { "amount" => "50" } ]
    )

    assert_equal true, result[:success], result[:message]
    assert_equal [ -150, -50 ], income.reload.child_entries.order(:created_at).pluck(:amount)
  end

  test "rejects negative amounts" do
    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "-10" }, { "amount" => "600" } ]
    )

    assert_equal "invalid_amount", result[:error]
    assert_not @entry.reload.split_parent?
  end

  test "rejects amounts with more than four decimal places instead of rounding them" do
    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "295.00004" }, { "amount" => "295.00004" } ]
    )

    assert_equal "invalid_amount", result[:error]
    assert_not @entry.reload.split_parent?
  end

  test "reports a saved split with a warning when the sync cannot be enqueued" do
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "queue down")

    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "295" }, { "amount" => "295" } ]
    )

    assert_equal true, result[:success]
    assert_match "could not be enqueued", result[:warning]
    assert @entry.reload.split_parent?
  end

  test "names parts after the original when no name is given" do
    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "290" }, { "amount" => "300" } ]
    )

    assert_equal true, result[:success], result[:message]
    assert_equal [ "Rent", "Rent" ], @entry.reload.child_entries.pluck(:name)
  end

  test "rejects amounts that do not sum to the original" do
    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "295" }, { "amount" => "290" } ]
    )

    assert_equal false, result[:success]
    assert_equal "amounts_do_not_sum", result[:error]
    assert_not @entry.reload.split_parent?
  end

  test "rejects a single part" do
    result = @function.call("id" => @transaction.id, "splits" => [ { "amount" => "590" } ])

    assert_equal "invalid_splits", result[:error]
  end

  test "rejects non-numeric amounts" do
    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "lots" }, { "amount" => "590" } ]
    )

    assert_equal "invalid_amount", result[:error]
  end

  test "rejects categories outside the family" do
    other = Category.create!(family: families(:empty), name: "Other", color: "#e99537", lucide_icon: "tag")

    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "295", "category_id" => other.id }, { "amount" => "295" } ]
    )

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
    assert_not @entry.reload.split_parent?
  end

  test "does not re-split unless replace_existing is set" do
    @entry.split!([ { name: "A", amount: 295 }, { name: "B", amount: 295 } ])

    result = @function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "390" }, { "amount" => "200" } ]
    )

    assert_equal "already_split", result[:error]
    assert_equal [ 295, 295 ], @entry.reload.child_entries.order(:created_at).pluck(:amount)
  end

  test "replaces the parts when replace_existing is set, addressed by a child id" do
    children = @entry.split!([ { name: "A", amount: 295 }, { name: "B", amount: 295 } ])

    result = @function.call(
      "id" => children.first.entryable_id,
      "replace_existing" => true,
      "splits" => [ { "amount" => "390" }, { "amount" => "100" }, { "amount" => "100" } ]
    )

    assert_equal true, result[:success], result[:message]
    assert_equal @transaction.id, result[:transaction][:id]
    assert_equal [ 390, 100, 100 ], @entry.reload.child_entries.order(:created_at).pluck(:amount)
  end

  test "refuses transfers" do
    result = @function.call(
      "id" => transactions(:transfer_out).id,
      "splits" => [ { "amount" => "50" }, { "amount" => "50" } ]
    )

    assert_equal false, result[:success]
    assert_equal "not_splittable", result[:error]
  end

  test "does not let read-only collaborators split" do
    entry = create_transaction(account: accounts(:credit_card), amount: 100)
    function = Assistant::Function::SplitTransaction.new(users(:family_member))

    result = function.call(
      "id" => entry.entryable_id,
      "splits" => [ { "amount" => "50" }, { "amount" => "50" } ]
    )

    assert_equal "not_authorized", result[:error]
    assert_not entry.reload.split_parent?
  end

  test "does not find transactions in another family" do
    function = Assistant::Function::SplitTransaction.new(users(:empty))

    result = function.call(
      "id" => @transaction.id,
      "splits" => [ { "amount" => "295" }, { "amount" => "295" } ]
    )

    assert_equal "not_found", result[:error]
  end
end
