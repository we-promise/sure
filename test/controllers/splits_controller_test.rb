require "test_helper"

class SplitsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @entry = create_transaction(
      amount: 100,
      name: "Grocery Store",
      account: accounts(:depository)
    )
  end

  test "new renders split editor" do
    get new_transaction_split_path(@entry)
    assert_response :success
  end

  test "create with valid params splits transaction" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.create.success"), flash[:notice]
    assert @entry.reload.excluded?
    assert @entry.split_parent?
  end

  test "create with mismatched amounts rejects" do
    assert_no_difference "Entry.count" do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Part 1", amount: "-60", category_id: "" },
            { name: "Part 2", amount: "-20", category_id: "" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    assert flash[:alert].present?
  end

  test "destroy unsplits transaction" do
    @entry.split!([
      { name: "Part 1", amount: 50, category_id: nil },
      { name: "Part 2", amount: 50, category_id: nil }
    ])

    assert_difference "Entry.count", -2 do
      delete transaction_split_path(@entry)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.destroy.success"), flash[:notice]
    refute @entry.reload.excluded?
  end

  test "create with income transaction applies correct sign" do
    income_entry = create_transaction(
      amount: -400,
      name: "Reimbursement",
      account: accounts(:depository)
    )

    assert_difference "Entry.count", 2 do
      post transaction_split_path(income_entry), params: {
        split: {
          splits: [
            { name: "Part 1", amount: "200", category_id: "" },
            { name: "Part 2", amount: "200", category_id: "" }
          ]
        }
      }
    end

    assert income_entry.reload.excluded?
    children = income_entry.child_entries
    assert_equal(-200, children.first.amount.to_i)
    assert_equal(-200, children.last.amount.to_i)
  end

  test "create with mixed sign amounts on expense" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Main expense", amount: "-130", category_id: "" },
            { name: "Refund", amount: "30", category_id: "" }
          ]
        }
      }
    end

    assert @entry.reload.excluded?
    children = @entry.child_entries.order(:amount)
    assert_equal(-30, children.first.amount.to_i)
    assert_equal 130, children.last.amount.to_i
  end

  test "only family members can access splits" do
    other_family_entry = create_transaction(
      amount: 100,
      name: "Other",
      account: accounts(:depository)
    )

    # This should work since both belong to same family
    get new_transaction_split_path(other_family_entry)
    assert_response :success
  end

  # Edit action tests
  test "edit renders with existing children pre-filled" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get edit_transaction_split_path(@entry)
    assert_response :success
  end

  test "edit on a child redirects to parent edit" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    child = @entry.child_entries.first

    get edit_transaction_split_path(child)
    assert_response :success
  end

  test "edit on a non-split entry redirects with alert" do
    get edit_transaction_split_path(@entry)
    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.edit.not_split"), flash[:alert]
  end

  # Update action tests
  test "update modifies split entries" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Food", amount: "-50", category_id: categories(:food_and_drink).id },
          { name: "Transport", amount: "-30", category_id: "" },
          { name: "Other", amount: "-20", category_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.update.success"), flash[:notice]
    @entry.reload
    assert @entry.split_parent?
    assert_equal 3, @entry.child_entries.count
  end

  test "update with mismatched amounts rejects" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-70", category_id: "" },
          { name: "Part 2", amount: "-20", category_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    assert flash[:alert].present?
    # Original splits should remain intact
    assert_equal 2, @entry.reload.child_entries.count
  end

  # Destroy from child tests
  test "destroy from child resolves to parent and unsplits" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    child = @entry.child_entries.first

    assert_difference "Entry.count", -2 do
      delete transaction_split_path(child)
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("splits.destroy.success"), flash[:notice]
    refute @entry.reload.excluded?
  end
end
