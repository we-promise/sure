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

  test "new groups subcategories immediately after their parent in the category selector" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    category_values = doc.css(".category-select-container [data-value]").map { |node| node["data-value"] }

    parent_index = category_values.index(categories(:food_and_drink).id)
    child_index = category_values.index(categories(:subcategory).id)

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "new gives each split row's pickers their own ids and labelled controls" do
    get new_transaction_split_path(@entry)
    assert_response :success

    doc = Nokogiri::HTML::Document.parse(response.body)
    ids = doc.css("[data-split-transaction-target='row'] [id]").map { |node| node["id"] }
    assert_empty ids.tally.select { |_id, count| count > 1 }.keys

    trigger = doc.at_css("#split_splits_0_category_id_trigger")
    assert_not_nil trigger
    assert_equal "split_splits_0_category_id_label split_splits_0_category_id_trigger", trigger["aria-labelledby"]

    %w[merchant_id tag_ids].each do |field|
      label = doc.at_css("label[for='split_splits_0_#{field}']")
      assert_not_nil label, "missing label for #{field}"
      assert_equal "button", doc.at_css("#split_splits_0_#{field}")&.name
    end
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

  test "create with excluded parameter sets child as excluded" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: categories(:food_and_drink).id, excluded: "true" },
            { name: "Household", amount: "-30", category_id: "", excluded: "false" }
          ]
        }
      }
    end

    assert_redirected_to transactions_url
    children = @entry.child_entries.order(:amount)
    # Household has amount 30 (smaller), Groceries has amount 70 (larger)
    # Household is NOT excluded, Groceries IS excluded
    refute children.first.excluded?
    assert children.last.excluded?
  end

  test "create with merchant and tags sets them on children" do
    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: "", merchant_id: merchants(:amazon).id, tag_ids: [ tags(:one).id, tags(:two).id ] },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    children = @entry.child_entries.order(:amount)
    groceries = children.find { |c| c.name == "Groceries" }
    household = children.find { |c| c.name == "Household" }

    assert_equal merchants(:amazon).id, groceries.entryable.merchant_id
    assert_equal [ tags(:one), tags(:two) ].sort_by(&:id), groceries.entryable.tags.sort_by(&:id)
    assert_nil household.entryable.merchant_id
  end

  test "create ignores merchant and tags belonging to another family" do
    other_family = families(:empty)
    foreign_merchant = other_family.merchants.create!(name: "Foreign merchant", type: "FamilyMerchant")
    foreign_tag = other_family.tags.create!(name: "Foreign tag")

    assert_difference "Entry.count", 2 do
      post transaction_split_path(@entry), params: {
        split: {
          splits: [
            { name: "Groceries", amount: "-70", category_id: "", merchant_id: foreign_merchant.id, tag_ids: [ foreign_tag.id ] },
            { name: "Household", amount: "-30", category_id: "" }
          ]
        }
      }
    end

    groceries = @entry.child_entries.order(:amount).find { |c| c.name == "Groceries" }
    assert_nil groceries.entryable.merchant_id
    assert_empty groceries.entryable.tags
  end

  test "create keeps a split row set to no merchant without one" do
    @entry.entryable.update!(merchant: merchants(:amazon))

    post transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Groceries", amount: "-70", category_id: "", merchant_id: SplitsHelper::NO_MERCHANT },
          { name: "Household", amount: "-30", category_id: "", merchant_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    children = @entry.reload.child_entries.index_by(&:name)
    assert_nil children["Groceries"].entryable.merchant_id
    assert children["Groceries"].entryable.locked?(:merchant_id)
    assert_equal merchants(:amazon), children["Household"].entryable.merchant
    refute children["Household"].entryable.locked?(:merchant_id)
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

  test "edit lists split rows in the order they were entered" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    @entry.child_entries.find_by!(name: "Part 2").update_columns(created_at: 1.day.ago)

    get edit_transaction_split_path(@entry)

    doc = Nokogiri::HTML::Document.parse(response.body)
    names = doc.css("[data-split-transaction-target='rowsContainer'] input[name$='[name]']").map { |input| input["value"] }
    assert_equal [ "Part 2", "Part 1" ], names
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

  test "update with excluded parameter sets child as excluded" do
    @entry.split!([
      { name: "Groceries", amount: 70, category_id: nil },
      { name: "Household", amount: 30, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Groceries", amount: "-70", category_id: "", excluded: "true" },
          { name: "Household", amount: "-30", category_id: "", excluded: "false" }
        ]
      }
    }

    assert_redirected_to transactions_url
    children = @entry.child_entries.order(:amount)
    refute children.first.excluded?
    assert children.last.excluded?
  end

  test "update sets merchant and tags on children" do
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: merchants(:netflix).id, tag_ids: [ tags(:three).id ] },
          { name: "Part 2", amount: "-40", category_id: "" }
        ]
      }
    }

    part_one = @entry.reload.child_entries.order(:amount).find { |c| c.name == "Part 1" }
    assert_equal merchants(:netflix).id, part_one.entryable.merchant_id
    assert_equal [ tags(:three) ], part_one.entryable.tags
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

  test "edit preselects each split's merchant" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil, merchant_id: merchants(:netflix).id },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    get edit_transaction_split_path(@entry)

    assert_equal merchants(:netflix).id, split_row_merchant_value("Part 1")
    # Part 2 follows the parent's merchant, so its picker starts on "(transaction's merchant)".
    assert_equal "", split_row_merchant_value("Part 2")
  end

  test "edit shows a split's own lack of merchant and a pinned parent merchant as its own" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    children = @entry.child_entries.index_by(&:name)
    # "(none)" picked in the split row's drawer
    children["Part 1"].entryable.update!(merchant: nil)
    children["Part 1"].entryable.lock_attr!(:merchant_id)
    # The parent's merchant picked in the drawer, so it no longer follows the parent
    children["Part 2"].entryable.lock_attr!(:merchant_id)

    get edit_transaction_split_path(@entry)

    assert_equal SplitsHelper::NO_MERCHANT, split_row_merchant_value("Part 1")
    assert_equal merchants(:amazon).id, split_row_merchant_value("Part 2")
    assert_select "[role=option][data-merchant-id=?]", SplitsHelper::NO_MERCHANT, text: I18n.t("splits.new.without_merchant")
  end

  test "update keeps a split without a merchant of its own without one" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: SplitsHelper::NO_MERCHANT },
          { name: "Part 2", amount: "-40", category_id: "", merchant_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    children = @entry.reload.child_entries.index_by(&:name)
    assert_nil children["Part 1"].entryable.merchant_id
    assert children["Part 1"].entryable.locked?(:merchant_id)
    assert_equal merchants(:amazon), children["Part 2"].entryable.merchant
    refute children["Part 2"].entryable.locked?(:merchant_id)

    # Neither survives as the parent's merchant when the parent changes later.
    @entry.entryable.update!(merchant: merchants(:netflix))
    assert_nil children["Part 1"].reload.entryable.merchant_id
    assert_equal merchants(:netflix), children["Part 2"].reload.entryable.merchant
  end

  test "update keeps a split's own merchant and gives other splits the parent's" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: merchants(:netflix).id },
          { name: "Part 2", amount: "-30", category_id: "", merchant_id: "" },
          { name: "Part 3", amount: "-10", category_id: "", merchant_id: merchants(:amazon).id }
        ]
      }
    }

    assert_redirected_to transactions_url
    children = @entry.reload.child_entries.index_by(&:name)
    assert_equal merchants(:netflix), children["Part 1"].entryable.merchant
    assert children["Part 1"].entryable.locked?(:merchant_id)
    assert_equal merchants(:amazon), children["Part 2"].entryable.merchant
    refute children["Part 2"].entryable.locked?(:merchant_id)
    # Picking the parent's merchant explicitly pins it to the split.
    assert_equal merchants(:amazon), children["Part 3"].entryable.merchant
    assert children["Part 3"].entryable.locked?(:merchant_id)
  end

  test "update gives a split left without a merchant the parent's, unlocked" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil, merchant_id: merchants(:netflix).id },
      { name: "Part 2", amount: 40, category_id: nil }
    ])

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: "" },
          { name: "Part 2", amount: "-40", category_id: "" }
        ]
      }
    }

    child = @entry.reload.child_entries.find_by(name: "Part 1")
    assert_equal merchants(:amazon), child.entryable.merchant
    refute child.entryable.locked?(:merchant_id)
  end

  test "update ignores a merchant the user cannot use" do
    @entry.entryable.update!(merchant: merchants(:amazon))
    @entry.split!([
      { name: "Part 1", amount: 60, category_id: nil },
      { name: "Part 2", amount: 40, category_id: nil }
    ])
    foreign_merchant = families(:empty).merchants.create!(name: "Foreign")

    patch transaction_split_path(@entry), params: {
      split: {
        splits: [
          { name: "Part 1", amount: "-60", category_id: "", merchant_id: foreign_merchant.id },
          { name: "Part 2", amount: "-40", category_id: "" }
        ]
      }
    }

    assert_redirected_to transactions_url
    child = @entry.reload.child_entries.find_by(name: "Part 1")
    assert_equal merchants(:amazon), child.entryable.merchant
    refute child.entryable.locked?(:merchant_id)
  end

  private

    # The merchant picker value of the split editor row with the given name.
    def split_row_merchant_value(name)
      doc = Nokogiri::HTML::Document.parse(response.body)
      prefix = doc.at_css("input[name$='[name]'][value='#{name}']")["name"].delete_suffix("[name]")
      doc.at_css("input[type=hidden][name='#{prefix}[merchant_id]']")["value"]
    end
end
