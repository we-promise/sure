require "test_helper"

class TransactionSortingTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  include ActionView::RecordIdentifier

  setup do
    sign_in users(:family_admin)
    @small = create_transaction(name: "Sort example small", amount: 5, date: Date.current)
    @large = create_transaction(name: "Sort example large", amount: 900, date: 3.days.ago.to_date)
    @income = create_transaction(name: "Sort example income", amount: -200, date: 1.day.ago.to_date)
    @zero = create_transaction(name: "Sort example zero", amount: 0, date: 2.days.ago.to_date)
  end

  test "sorts magnitudes across dates in both directions and retains row dates" do
    get transactions_path, params: { q: { search: "Sort example" }, sort: "amount_desc" }
    assert_response :success
    assert_rows [ @large, @income, @small, @zero ]
    assert_select "##{dom_id(@large)} time[datetime=?]", @large.date.iso8601
    assert_select "input[name=sort][value=amount_desc]"

    get transactions_path, params: { q: { search: "Sort example" }, sort: "amount_asc" }
    assert_rows [ @zero, @small, @income, @large ]
  end

  test "sorts before pagination with deterministic ties and preserves filters in links" do
    tied = 11.times.map do |i|
      create_transaction(name: "Sort tied #{i}", amount: 25, date: Date.current, created_at: Time.current.beginning_of_day)
    end
    expected = tied.sort_by(&:id).reverse

    get transactions_path, params: { q: { search: "Sort tied" }, sort: "amount_desc", per_page: 10 }
    assert_response :success
    assert_rows expected.first(10)
    assert_select "a[href*='sort=amount_desc'][href*='page=2']"
    assert_select "a[href*='sort=amount_asc'][href*='Sort+tied']"

    get transactions_path, params: { q: { search: "Sort tied" }, sort: "amount_desc", per_page: 10, page: 2 }
    assert_rows expected.last(1)
    assert_select "a[href*='sort=amount_asc'][href*='page=2']", count: 0
  end

  test "invalid sorting falls back to newest first and sort survives filter clearing and restoration" do
    get transactions_path, params: { q: { search: "Sort example" }, sort: "amount; DROP TABLE entries" }
    assert_rows [ @small, @income, @zero, @large ]
    assert_select "input[name=sort][value=date_desc]"

    get transactions_path, params: { q: { search: "Sort example" }, sort: "amount_asc" }
    get transactions_path
    assert_redirected_to transactions_path(q: { search: "Sort example" }, sort: "amount_asc", page: 1, per_page: 50)

    delete clear_filter_transactions_path, params: { q: { search: "Sort example" }, param_key: "search", sort: "amount_asc" }
    assert_response :redirect
    assert_includes response.location, "sort=amount_asc"
  end

  test "amount sorting retains account access and tag filters" do
    @large.entryable.tags << tags(:one)
    @small.entryable.tags << tags(:one)
    private_account = families(:empty).accounts.create!(name: "Private", balance: 0, currency: "USD", accountable: Depository.new)
    inaccessible = create_transaction(name: "Sort example private", account: private_account, amount: 5000)

    get transactions_path, params: { q: { search: "Sort example", tags: [ tags(:one).name ] }, sort: "amount_desc" }
    assert_response :success
    assert_rows [ @large, @small ]
    assert_select "##{dom_id(inaccessible)}", count: 0
  end

  test "default sorting does not introduce a restoration redirect" do
    2.times do
      get transactions_path
      assert_response :success
    end
  end

  test "split children retain amount order even when grouped splits are preferred" do
    assert users(:family_admin).show_split_grouped?
    @large.split!([
      { name: "Sort example part one", amount: 850, category_id: nil },
      { name: "Sort example part two", amount: 50, category_id: nil }
    ])
    children = @large.child_entries.order(amount: :desc).to_a

    get transactions_path, params: { q: { search: "Sort example" }, sort: "amount_desc" }
    assert_response :success
    assert_rows [ children.first, @income, children.last, @small, @zero ]
    assert_select ".split-group", count: 0
  end

  test "transfer deduplication fills pages and does not repeat transfers on the next page" do
    transfer = create_transfer(from_account: accounts(:depository), to_account: accounts(:credit_card), amount: 50)
    outflow = transfer.outflow_transaction.reload.entry
    inflow = transfer.inflow_transaction.reload.entry
    [ outflow, inflow ].each { |entry| entry.update!(name: "Sort boundary transfer") }
    # The raw order places the outflow at position 10 and inflow at 11.
    outflow.update!(created_at: 1.hour.ago)
    inflow.update!(created_at: 2.hours.ago)
    larger = 9.times.map do |i|
      create_transaction(name: "Sort boundary #{i}", amount: 100 + i, date: Date.current)
    end
    smaller = create_transaction(name: "Sort boundary small", amount: 10)

    get transactions_path, params: { q: { search: "Sort boundary" }, sort: "amount_desc", per_page: 10 }
    assert_response :success
    assert_rows larger.reverse + [ outflow ]

    get transactions_path, params: { q: { search: "Sort boundary" }, sort: "amount_desc", per_page: 10, page: 2 }
    assert_response :success
    assert_rows [ smaller ]

    # Put both transfer legs on page one in the raw ascending order. The
    # displayed first page must still contain ten rows, not nine.
    get transactions_path, params: { q: { search: "Sort boundary" }, sort: "amount_asc", per_page: 10 }
    assert_rows [ smaller, outflow ] + larger.first(8)
    get transactions_path, params: { q: { search: "Sort boundary" }, sort: "amount_asc", per_page: 10, page: 2 }
    assert_rows larger.last(1)
  end

  private
    def assert_rows(entries)
      assert_select "#transactions turbo-frame[id^='entry_']" do |rows|
        assert_equal entries.map { |entry| dom_id(entry) }, rows.map { |row| row["id"] }
      end
    end
end
