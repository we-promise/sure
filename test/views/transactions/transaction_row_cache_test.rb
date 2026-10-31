require "test_helper"

class Transactions::TransactionRowCacheTest < ActionView::TestCase
  include TransactionsHelper

  setup do
    Current.session = Session.create!(user: users(:family_admin))

    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id).to_set
    @split_parent_entry_ids = Set.new

    @entry = entries(:transaction)
    @transaction = @entry.transaction
    @category = categories(:food_and_drink)
    @transaction.update!(category: @category)

    # The test environment uses :null_store, which would make every assertion
    # below pass without exercising the cache.
    controller.perform_caching = true
    controller.cache_store = ActiveSupport::Cache::MemoryStore.new
  end

  test "an unchanged row is served from the cache" do
    original_name = @entry.name
    assert_includes render_row, original_name

    # update_all leaves updated_at alone, so only a cache hit can show the old name.
    Entry.where(id: @entry.id).update_all(name: "Renamed behind the cache")

    html = render_row
    assert_includes html, original_name
    assert_not_includes html, "Renamed behind the cache"
  end

  test "editing the entry, category, tags or account renders the row fresh" do
    render_row

    @entry.update!(name: "Renamed entry")
    assert_includes render_row, "Renamed entry"

    @category.update!(name: "Renamed category")
    assert_includes render_row, "Renamed category"

    tag = Tag.create!(family: @entry.account.family, name: "Fresh tag")
    @transaction.update!(tag_ids: [ tag.id ])
    assert_includes render_row, "Fresh tag"

    tag.update!(name: "Renamed tag")
    assert_includes render_row, "Renamed tag"

    @entry.account.update!(name: "Renamed account")
    assert_includes render_row, "Renamed account"
  end

  test "the key depends on the viewer, locale, view context and grouping" do
    base = row_key

    assert_not_equal base, row_key(view_ctx: "account")
    assert_not_equal base, row_key(in_split_group: true)
    assert_not_equal base, I18n.with_locale(:de) { row_key }

    Current.session = Session.create!(user: users(:family_member))
    assert_not_equal base, row_key
  end

  test "renaming the merchant renders the row fresh, a balance sync does not" do
    merchant = merchants(:netflix)
    @transaction.update!(merchant: merchant)
    render_row

    merchant.update!(name: "Renamed merchant")
    assert_includes render_row, "Renamed merchant"

    # A sync rewrites the account balance; the row doesn't show it, so it
    # stays cached (update_all keeps the entry's own version unchanged).
    Entry.where(id: @entry.id).update_all(name: "Renamed behind the cache")
    @entry.account.update!(balance: @entry.account.balance + 1)
    assert_not_includes render_row, "Renamed behind the cache"
  end

  test "an inflow row's key follows the outflow leg and the counterpart account" do
    transfer = transfers(:one)
    inflow_entry = transfer.inflow_transaction.entry
    base = row_key(entry: inflow_entry)

    transfer.outflow_transaction.update!(kind: "loan_payment")
    assert_not_equal base, (base = row_key(entry: inflow_entry))

    transfer.outflow_transaction.update!(category: @category)
    assert_not_equal base, (base = row_key(entry: inflow_entry))

    @category.update!(name: "Renamed category")
    assert_not_equal base, (base = row_key(entry: inflow_entry))

    transfer.from_account.update!(name: "Renamed counterpart")
    assert_not_equal base, row_key(entry: inflow_entry)
  end

  # The confirm and reject forms of a pending transfer match embed the
  # session's CSRF token, which a cached row would hand to other sessions.
  test "a row with a pending transfer match is never served from the cache" do
    @entry = transfers(:one).tap { |t| t.update!(status: "pending") }.inflow_transaction.entry
    render_row

    Entry.where(id: @entry.id).update_all(name: "Renamed behind the cache")

    assert_includes render_row, "Renamed behind the cache"
  end

  # A crypto account's subtype decides whether its rows show the activity
  # label or the category menu, and changing it leaves the account's
  # displayed attributes as they were.
  test "the key changes when the account starts supporting trades" do
    base = row_key

    Account.any_instance.stubs(:supports_trades?).returns(true)

    assert_not_equal base, row_key
  end

  test "the key carries a digest of the row's templates and components" do
    TransactionsHelper::TRANSACTION_ROW_SOURCES.each do |pattern|
      assert Dir[Rails.root.join(pattern).to_s].any?, "#{pattern} matches no file"
    end

    assert_includes row_key, TransactionsHelper::TRANSACTION_ROW_SOURCES_DIGEST
  end

  test "the key changes with the BUILD_COMMIT_SHA of the deployed image" do
    base = row_key

    with_env_overrides("BUILD_COMMIT_SHA" => "abc1234") do
      assert_not_equal base, row_key
    end
  end

  private
    def row_key(entry: @entry, view_ctx: "global", in_split_group: false)
      transaction_row_cache_key(entry.reload, view_ctx: view_ctx, in_split_group: in_split_group)
    end

    def render_row
      render(partial: "transactions/transaction", locals: { entry: @entry.reload, balance_trend: nil, view_ctx: "global" })
    end
end
