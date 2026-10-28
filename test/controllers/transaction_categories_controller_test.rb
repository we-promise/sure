require "test_helper"

class TransactionCategoriesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @entry = entries(:transaction)
    @transaction = transactions(:one)
  end

  test "assigning a category touches its last_used_at" do
    category = categories(:income)
    assert_nil category.last_used_at

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_not_nil category.reload.last_used_at
  end

  test "clearing a category does not touch any category's last_used_at" do
    category = @transaction.category
    assert_nil category.last_used_at

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: nil } } },
      as: :turbo_stream

    assert_response :success
    assert_nil @transaction.reload.category_id
    assert_nil category.reload.last_used_at
  end

  test "offers a rule prompt when the chosen category's existing rule does not cover this transaction" do
    category = categories(:income)
    @entry.update!(name: "AMZN Mktp UK")
    rule = @entry.account.family.rules.build(name: "Amazon", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "AMAZON.CO.UK")
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_response :success
    # The prompt is rendered into the turbo-stream response (flash is cleared once rendered).
    assert_match %r{/rules/new\?[^"]*action_value=#{category.id}}, response.body
  end

  test "does not offer a rule prompt when an existing rule already covers this transaction" do
    category = categories(:income)
    @entry.update!(name: "AMZN Mktp UK")
    rule = @entry.account.family.rules.build(name: "Amazon", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "AMZN")
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_response :success
    assert_not_includes response.body, "action_type=set_transaction_category"
  end

  test "does not offer guests to create a rule they cannot save" do
    category = categories(:income)
    @entry.update!(name: "AMZN Mktp UK")
    rule = @entry.account.family.rules.build(name: "Amazon", resource_type: "transaction", active: true)
    rule.conditions.build(condition_type: "transaction_name", operator: "like", value: "AMAZON.CO.UK")
    rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
    rule.save!
    @entry.account.update!(owner: family_guest)
    sign_in family_guest

    patch transaction_category_url(@entry),
      params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: @transaction.id, category_id: category.id } } },
      as: :turbo_stream

    assert_response :success
    assert_equal category.id, @transaction.reload.category_id
    assert_not_includes response.body, "action_type=set_transaction_category"
  end

  test "a matched transfer's inflow leg does not take a category" do
    outflow, inflow = create_contribution_transfer
    category = categories(:income)

    patch transaction_category_url(inflow.entry),
          params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: inflow.id, category_id: category.id } } },
          as: :turbo_stream

    assert_response :unprocessable_entity
    assert_nil inflow.reload.category_id
    assert_nil outflow.reload.category_id
  end

  test "a matched transfer's outflow leg still takes a category" do
    outflow, _inflow = create_contribution_transfer
    category = categories(:income)

    patch transaction_category_url(outflow.entry),
          params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: outflow.id, category_id: category.id } } },
          as: :turbo_stream

    assert_response :success
    assert_equal category, outflow.reload.category
  end

  test "refreshes the read-only investment inflow when a contribution outflow's category changes" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: 500, kind: "investment_contribution")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction, status: "confirmed")

    patch_category(outflow_entry, categories(:income))

    assert_counterpart_streams(inflow_entry.transaction, categories(:income))
  end

  test "refreshes the read-only investment outflow when a withdrawal's cash leg category changes" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: 500, kind: "funds_movement")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction, status: "confirmed")

    patch_category(inflow_entry, categories(:income))

    assert_equal categories(:income), inflow_entry.transaction.reload.category
    assert_counterpart_streams(outflow_entry.transaction, categories(:income))
  end

  test "refuses a category on the investment outflow of a withdrawal" do
    outflow_entry = create_transaction(date: Date.current, account: accounts(:investment), amount: 500, kind: "funds_movement")
    inflow_entry = create_transaction(date: Date.current, account: accounts(:depository), amount: -500, kind: "funds_movement")
    Transfer.create!(inflow_transaction: inflow_entry.transaction, outflow_transaction: outflow_entry.transaction, status: "confirmed")

    patch_category(outflow_entry, categories(:income))

    assert_response :unprocessable_entity
    assert_nil outflow_entry.transaction.reload.category
  end

  private
    def create_contribution_transfer
      outflow = Transaction.create!(kind: "investment_contribution")
      Entry.create!(account: accounts(:depository), entryable: outflow, name: "Contribution", amount: 500, currency: "USD", date: Date.current)
      inflow = Transaction.create!(kind: "funds_movement")
      Entry.create!(account: accounts(:investment), entryable: inflow, name: "Contribution", amount: -500, currency: "USD", date: Date.current)
      Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")
      [ outflow, inflow ]
    end
    def patch_category(entry, category)
      patch transaction_category_url(entry),
        params: { entry: { entryable_type: "Transaction", entryable_attributes: { id: entry.transaction.id, category_id: category.id } } },
        as: :turbo_stream
    end

    def assert_counterpart_streams(counterpart, category)
      assert_response :success
      [ dom_id(counterpart, "category_menu_desktop"), dom_id(counterpart, "category_menu_mobile"), "category_name_mobile_#{counterpart.id}" ].each do |target|
        stream = response.body[/<turbo-stream action="replace" target="#{target}">.*?<\/turbo-stream>/m]
        assert stream, "expected a replacement for #{target}"
        assert_includes stream, category.name
      end
    end
end
