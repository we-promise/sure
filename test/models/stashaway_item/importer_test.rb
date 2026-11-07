require "test_helper"

class StashawayItem::ImporterTest < ActiveSupport::TestCase
  include StashawayTestHelper

  setup do
    @item = stashaway_items(:connected)
    @provider = Provider::Stashaway.new(region: "sg", token: "test-api-token")
  end

  test "groups portfolios of the same name, funding source and type into one account" do
    @provider.stubs(:goals).returns([
      { "_id" => "a", "displayName" => "Simple SGD ", "goalType" => "SIMPLE", "fundingSource" => "PERSONAL", "state" => "ARCHIVED", "currency" => "SGD" },
      { "_id" => "b", "displayName" => "simple sgd", "goalType" => "SIMPLE", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" },
      { "_id" => "c", "displayName" => "Retirement 🌴", "goalType" => "CUSTOM", "fundingSource" => "SRS", "state" => "ACTIVE", "currency" => "SGD" },
      { "_id" => "d", "displayName" => "FD 1", "goalType" => "FIXED", "fundingSource" => "PERSONAL", "state" => "CLOSED", "currency" => "SGD" },
      { "_id" => "e", "displayName" => "Empty", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" }
    ])
    stub_goal("a", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ], nav: 0)
    stub_goal("b", rows: [ stashaway_row("d2", "2026-01-20", "Deposit", 50) ], nav: 50)
    stub_goal("c", rows: [ stashaway_row("d3", "2026-01-20", "Deposit", 10) ], nav: 11)
    stub_goal("e", rows: [], nav: nil)
    @provider.expects(:goal_transactions).with("d").never

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 2, result[:accounts]
    simple = @item.stashaway_accounts.find_by!(group_key: "simple sgd|PERSONAL|SIMPLE")
    assert_equal "simple sgd", simple.name, "named after the active portfolio"
    assert_equal %w[b a], simple.goals.map { |goal| goal["id"] }
    assert_equal "Depository", simple.accountable_type
    assert_equal 50, simple.current_balance
    assert_equal Date.new(2026, 1, 31), simple.last_nav_date

    retirement = @item.stashaway_accounts.find_by!(group_key: "retirement|SRS|CUSTOM")
    assert_equal "Retirement 🌴", retirement.name
    assert_equal [ "Investment", "retirement" ], [ retirement.accountable_type, retirement.accountable_subtype ]

    assert_nil @item.stashaway_accounts.find_by(group_key: "fd 1|PERSONAL|FIXED"), "closed portfolios get no account"
    assert_nil @item.stashaway_accounts.find_by(group_key: "empty|PERSONAL|CUSTOM"), "empty portfolios get no account"
    assert @item.save, "skipped portfolios leave nothing unsaved on the item"
  end

  test "values a linked account's portfolios in its currency and in each row's currency" do
    stashaway_accounts(:general).link_to!(usd_account)
    @provider.stubs(:goals).returns([ general_goal("ACTIVE") ])
    @provider.stubs(:goal_transactions).with("g1").returns([ stashaway_row("e1", "2026-01-20", "Entitlement", 1, "EUR") ])
    %w[USD SGD EUR].each do |currency|
      @provider.expects(:goal_performance).with("g1", currency).returns({ "nav" => stashaway_daily("2026-01-20", "2026-01-31") { 1 } })
    end

    StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal %w[EUR SGD USD], stashaway_accounts(:general).reload.goals.sole["performance"].keys.sort
  end

  test "a portfolio StashAway cannot find keeps the detail stored for it" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([ general_goal("ARCHIVED") ])
    @provider.stubs(:goal_transactions).raises(Provider::Stashaway::NotFound.new("Goal not found"))

    StashawayItem::Importer.new(@item, provider: @provider).import

    record = stashaway_accounts(:general).reload.goals.sole
    assert_equal [ "not found", "ARCHIVED" ], [ record["unavailable"], record["state"] ]
    assert_equal [ "gd1" ], record["transactions"].map { |item| item["id"] }
    assert_equal [ "SGD" ], record["performance"].keys
  end

  test "a portfolio that was closed keeps the detail stored for it and is worth nothing" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([ general_goal("CLOSED") ])
    @provider.expects(:goal_transactions).never

    StashawayItem::Importer.new(@item, provider: @provider).import

    general = stashaway_accounts(:general).reload
    record = general.goals.sole
    assert_equal [ "closed", "CLOSED", [ "gd1" ] ], [ record["unavailable"], record["state"], record["transactions"].map { |item| item["id"] } ]
    assert_equal 0, general.current_balance
    assert_equal Date.new(2026, 2, 1), general.last_nav_date, "the day after its last valued day"
  end

  test "a portfolio whose detail request fails keeps the detail stored for it while the others import" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([
      general_goal("ACTIVE"),
      { "_id" => "g2", "displayName" => "Other", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" }
    ])
    @provider.stubs(:goal_transactions).with("g1").raises(Provider::Stashaway::ApiError.new("StashAway request failed (HTTP 500)", status_code: 500))
    stub_goal("g2", rows: [ stashaway_row("d2", "2026-01-20", "Deposit", 10) ], nav: 10)

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 2, result[:accounts]
    record = stashaway_accounts(:general).reload.goals.sole
    assert_equal [ "error", [ "gd1" ], [ "SGD" ] ], [ record["unavailable"], record["transactions"].map { |item| item["id"] }, record["performance"].keys ]
    assert @item.stashaway_accounts.exists?(group_key: "other|PERSONAL|CUSTOM")
    assert DebugLogEntry.where("message LIKE ?", "%HTTP 500%detail stored for it last is used%").exists?
  end

  test "a portfolio StashAway no longer lists keeps the detail stored for it" do
    second = stashaway_goal("g2",
      transactions: [ stashaway_row("d2", "2026-01-10", "Deposit", 20) ],
      nav: { "SGD" => stashaway_daily("2026-01-10", "2026-01-31") { 20 } })
    stashaway_accounts(:general).update!(raw_goals_payload: [ stored_goal, second ])
    @provider.stubs(:goals).returns([ general_goal("ACTIVE") ])
    stub_goal("g1", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ], nav: 50)

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 1, result[:accounts]
    general = stashaway_accounts(:general).reload
    assert_equal %w[g1 g2], general.goals.map { |goal| goal["id"] }
    unlisted = general.goals.last
    assert_equal [ "unlisted", "ACTIVE", [ "gd2" ], [ "SGD" ] ], [ unlisted["unavailable"], unlisted["state"], unlisted["transactions"].map { |item| item["id"] }, unlisted["performance"].keys ]
    assert_equal %w[g1 g2], general.goal_ids, "still held, so it is matched by id if listed again"
    assert_equal 70, general.current_balance, "its last value carries forward"
    assert_equal 1, DebugLogEntry.where("message LIKE ?", "%no longer lists portfolio g2%").count

    StashawayItem::Importer.new(@item, provider: @provider).import
    assert_equal 1, DebugLogEntry.where("message LIKE ?", "%no longer lists portfolio g2%").count, "logged once"
  end

  test "an account none of whose portfolios StashAway lists keeps its detail, logged against its link" do
    store_general(stored_goal)
    general = stashaway_accounts(:general)
    link = AccountProvider.create!(account: families(:dylan_family).accounts.create!(name: "StashAway SG: General", balance: 0, currency: "SGD", accountable: Investment.new), provider: general)
    @provider.stubs(:goals).returns([])

    StashawayItem::Importer.new(@item, provider: @provider).import

    record = general.reload.goals.sole
    assert_equal [ "g1", "unlisted", [ "gd1" ] ], [ record["id"], record["unavailable"], record["transactions"].map { |item| item["id"] } ]
    assert_equal "General Investing", general.name, "keeps its name with no listed portfolio"
    entry = DebugLogEntry.where("message LIKE ?", "%no longer lists portfolio g1%").sole
    assert_equal link, entry.account_provider
  end

  test "a portfolio whose value request fails after its transactions keeps the detail stored for it" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([
      general_goal("ACTIVE"),
      { "_id" => "g2", "displayName" => "Other", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" }
    ])
    @provider.stubs(:goal_transactions).with("g1").returns([ stashaway_row("d1", "2026-01-05", "Deposit", 50), stashaway_row("d9", "2026-02-02", "Deposit", 5) ])
    @provider.stubs(:goal_transactions).with("g2").returns([ stashaway_row("d2", "2026-01-20", "Deposit", 10) ])
    @provider.stubs(:goal_performance).raises(Provider::Stashaway::ApiError.new("StashAway request failed (HTTP 502)", status_code: 502))

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 1, result[:accounts]
    record = stashaway_accounts(:general).reload.goals.sole
    assert_equal [ "error", [ "gd1" ], [ "SGD" ] ], [ record["unavailable"], record["transactions"].map { |item| item["id"] }, record["performance"].keys ], "the stored detail stands in whole"
    assert_nil @item.stashaway_accounts.find_by(group_key: "other|PERSONAL|CUSTOM"), "a new portfolio with no value yet gets no account"
  end

  test "an import whose value cannot be used keeps the account's last valuation" do
    store_general(stored_goal)
    stashaway_accounts(:general).update!(current_balance: 50, last_nav_date: Date.new(2026, 1, 31))
    @provider.stubs(:goals).returns([ general_goal("ACTIVE") ])
    stub_goal("g1", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50), stashaway_row("d2", "2026-02-03", "Deposit", 20) ], nav: nil)

    StashawayItem::Importer.new(@item, provider: @provider).import

    account = stashaway_accounts(:general).reload
    assert_equal [ 50, Date.new(2026, 1, 31) ], [ account.current_balance, account.last_nav_date ]
    assert_equal %w[gd1 gd2], account.goals.sole["transactions"].map { |item| item["id"] }, "the new detail is stored all the same"
  end

  test "a refused sign-in fails the import instead of marking the portfolio unavailable" do
    @provider.stubs(:goals).returns([ general_goal("ACTIVE") ])
    @provider.stubs(:goal_transactions).raises(Provider::Stashaway::AuthenticationError, "StashAway sign-in has expired (HTTP 401)")

    assert_raises(Provider::Stashaway::AuthenticationError) { StashawayItem::Importer.new(@item, provider: @provider).import }
  end

  test "a renamed portfolio stays with its account, which takes the new name" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([ general_goal("ACTIVE").merge("displayName" => "Retirement Fund") ])
    stub_goal("g1", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ], nav: 50)

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 1, result[:accounts]
    assert_equal [ stashaway_accounts(:general).id ], @item.stashaway_accounts.ids, "no account for the new name"
    general = stashaway_accounts(:general).reload
    assert_equal [ "Retirement Fund", "retirement fund|PERSONAL|CUSTOM", [ "g1" ] ], [ general.name, general.group_key, general.goals.map { |goal| goal["id"] } ]
  end

  test "a new portfolio joins the account whose portfolios share its name now, not the name they had" do
    store_general(stored_goal)
    @provider.stubs(:goals).returns([
      general_goal("ACTIVE").merge("displayName" => "Retirement Fund"),
      { "_id" => "g2", "displayName" => "Retirement Fund", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" },
      { "_id" => "g3", "displayName" => "General Investing", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" }
    ])
    stub_goal("g1", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ], nav: 50)
    stub_goal("g2", rows: [ stashaway_row("d2", "2026-01-20", "Deposit", 20) ], nav: 20)
    stub_goal("g3", rows: [ stashaway_row("d3", "2026-01-20", "Deposit", 10) ], nav: 10)

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 2, result[:accounts]
    general = stashaway_accounts(:general).reload
    assert_equal %w[g1 g2], general.goals.map { |goal| goal["id"] }.sort
    other = @item.stashaway_accounts.where.not(id: general.id).sole
    assert_equal [ "General Investing", "general investing|PERSONAL|CUSTOM", [ "g3" ] ], [ other.name, other.group_key, other.goals.map { |goal| goal["id"] } ]
  end

  test "two accounts whose portfolios come to share a name both keep theirs" do
    store_general(stored_goal)
    travel = @item.stashaway_accounts.create!(
      group_key: "travel|PERSONAL|CUSTOM", name: "Travel", goal_type: "CUSTOM", funding_source: "PERSONAL", currency: "SGD",
      raw_goals_payload: [ stashaway_goal("g2", name: "Travel", transactions: [ stashaway_row("d2", "2026-01-05", "Deposit", 20) ], nav: { "SGD" => stashaway_daily("2026-01-05", "2026-01-31") { 20 } }) ]
    )
    @provider.stubs(:goals).returns([
      general_goal("ACTIVE"),
      { "_id" => "g2", "displayName" => "General Investing", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => "ACTIVE", "currency" => "SGD" }
    ])
    stub_goal("g1", rows: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ], nav: 50)
    stub_goal("g2", rows: [ stashaway_row("d2", "2026-01-05", "Deposit", 20) ], nav: 20)

    result = StashawayItem::Importer.new(@item, provider: @provider).import

    assert_equal 2, result[:accounts]
    assert_equal [ "g1" ], stashaway_accounts(:general).reload.goals.map { |goal| goal["id"] }
    travel.reload
    assert_equal [ "General Investing", "general investing|PERSONAL|CUSTOM", [ "g2" ] ], [ travel.name, travel.group_key, travel.goals.map { |goal| goal["id"] } ]
    assert_equal 2, @item.stashaway_accounts.where(group_key: "general investing|PERSONAL|CUSTOM").count
  end

  private

    def stub_goal(id, rows:, nav:)
      @provider.stubs(:goal_transactions).with(id).returns(rows)
      points = nav.nil? ? [] : stashaway_daily("2026-01-05", "2026-01-31") { nav }
      @provider.stubs(:goal_performance).with(id, anything).returns({ "nav" => points, "net_deposits" => [] })
    end

    # The goal list entry of the `general` fixture's portfolio.
    def general_goal(state)
      { "_id" => "g1", "displayName" => "General Investing", "goalType" => "CUSTOM", "fundingSource" => "PERSONAL", "state" => state, "currency" => "SGD" }
    end

    # The detail an earlier import stored for that portfolio.
    def stored_goal
      stashaway_goal("g1",
        transactions: [ stashaway_row("d1", "2026-01-05", "Deposit", 50) ],
        nav: { "SGD" => stashaway_daily("2026-01-05", "2026-01-31") { 50 } })
    end

    def store_general(goal)
      stashaway_accounts(:general).update!(raw_goals_payload: [ goal ])
    end

    def usd_account
      families(:dylan_family).accounts.create!(name: "USD portfolio", balance: 0, currency: "USD", accountable: Investment.new)
    end
end
