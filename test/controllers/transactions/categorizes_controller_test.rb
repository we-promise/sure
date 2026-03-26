require "test_helper"

class Transactions::CategorizesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    # Clear entries for isolation
    @family.accounts.each { |a| a.entries.delete_all }
  end

  # GET /transactions/categorize

  test "show redirects with notice when nothing to categorize" do
    get transactions_categorize_url
    assert_redirected_to transactions_url
    assert_match "categorized", flash[:notice]
  end

  test "show renders wizard when uncategorized transactions exist" do
    create_transaction(account: @account, name: "Starbucks")
    get transactions_categorize_url
    assert_response :success
  end

  test "show renders the first group at position 0" do
    2.times { create_transaction(account: @account, name: "Netflix") }
    3.times { create_transaction(account: @account, name: "Starbucks") }

    get transactions_categorize_url(position: 0)

    assert_response :success
    assert_select "h2", text: "Starbucks"
  end

  test "show at position 1 skips first group" do
    3.times { create_transaction(account: @account, name: "Starbucks") }
    2.times { create_transaction(account: @account, name: "Netflix") }

    get transactions_categorize_url(position: 1)

    assert_response :success
    assert_select "h2", text: "Netflix"
  end

  test "show redirects when position exceeds available groups" do
    create_transaction(account: @account, name: "Starbucks")

    get transactions_categorize_url(position: 99)

    assert_redirected_to transactions_url
  end

  test "requires authentication" do
    sign_out
    get transactions_categorize_url
    assert_redirected_to new_session_url
  end

  private

    def sign_out
      @user.sessions.each { |s| delete session_path(s) }
    end

  # POST /transactions/categorize

  test "create categorizes selected entries and returns redirect stream when all assigned" do
    entry = create_transaction(account: @account, name: "Starbucks")

    post transactions_categorize_url,
      params: {
        position: 0,
        grouping_key: "Starbucks",
        entry_ids: [ entry.id ],
        all_entry_ids: [ entry.id ],
        category_id: @category.id
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal @category, entry.transaction.reload.category
    assert_includes response.body, "action=\"redirect\""
  end

  test "create removes assigned rows and replaces remaining when partial assignment" do
    entry1 = create_transaction(account: @account, name: "Starbucks")
    entry2 = create_transaction(account: @account, name: "Starbucks")

    post transactions_categorize_url,
      params: {
        position: 0,
        grouping_key: "Starbucks",
        entry_ids: [ entry1.id ],
        all_entry_ids: [ entry1.id, entry2.id ],
        category_id: @category.id
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal @category, entry1.transaction.reload.category
    assert_nil entry2.transaction.reload.category
    # Remove stream for categorized entry
    assert_includes response.body, "categorize_entry_#{entry1.id}"
    # Replace stream for remaining entry (re-checked)
    assert_includes response.body, "categorize_entry_#{entry2.id}"
    # No redirect stream — still in the group
    assert_not_includes response.body, "action=\"redirect\""
  end

  test "create with create_rule param creates rule directly" do
    entry = create_transaction(account: @account, name: "Netflix")

    assert_difference "@family.rules.count", 1 do
      post transactions_categorize_url,
        params: {
          position: 0,
          grouping_key: "Netflix",
          entry_ids: [ entry.id ],
          all_entry_ids: [ entry.id ],
          category_id: @category.id,
          create_rule: "1"
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    rule = @family.rules.find_by(name: "Netflix")
    assert_not_nil rule
    assert rule.active
  end

  test "create falls back to html redirect without turbo stream header" do
    entry = create_transaction(account: @account, name: "Starbucks")

    post transactions_categorize_url, params: {
      position: 0,
      grouping_key: "Starbucks",
      entry_ids: [ entry.id ],
      all_entry_ids: [ entry.id ],
      category_id: @category.id
    }

    assert_redirected_to transactions_categorize_url(position: 0)
    assert flash[:notice].present?
  end

  # PATCH /transactions/categorize/assign_entry

  test "assign_entry categorizes single entry and returns remove stream" do
    entry = create_transaction(account: @account, name: "Starbucks")
    other = create_transaction(account: @account, name: "Starbucks")

    patch assign_entry_transactions_categorize_url, params: {
      entry_id: entry.id,
      category_id: @category.id,
      position: 0,
      all_entry_ids: [ entry.id, other.id ]
    }

    assert_response :success
    assert_equal @category, entry.transaction.reload.category
    assert_includes response.body, "categorize_entry_#{entry.id}"
    assert_not_includes response.body, "action=\"redirect\""
  end

  test "assign_entry returns redirect stream when last entry in group" do
    entry = create_transaction(account: @account, name: "Starbucks")

    patch assign_entry_transactions_categorize_url, params: {
      entry_id: entry.id,
      category_id: @category.id,
      position: 0,
      all_entry_ids: [ entry.id ]
    }

    assert_response :success
    assert_includes response.body, "action=\"redirect\""
  end
end
