require "test_helper"

class StashawayAccount::ProcessorTest < ActiveSupport::TestCase
  include StashawayTestHelper, EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @stashaway_account = stashaway_accounts(:general)
    @fees = @family.categories.create!(name: "Fees", color: "#e99537", lucide_icon: "receipt")
    travel_to Date.new(2026, 2, 16)
  end

  test "imports the whole history into a new account and anchors its balance on StashAway's value" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account

    process

    entries = account.entries.where(source: "stashaway").order(:date)
    assert_equal [ "tx:d1", "ret:2026-01", "tx:f1", "tx:e1", "ret:2026-02" ], entries.map(&:external_id)
    assert_equal 1020, account.reload.balance
    assert_equal 1020, account.current_anchor_balance
    assert_equal categories(:income), entries.find_by(external_id: "tx:e1").transaction.category
    assert_equal @fees, entries.find_by(external_id: "tx:f1").transaction.category
    assert_nil entries.find_by(external_id: "ret:2026-01").transaction.category, "no Investment Returns category in this family"
    deposit = entries.find_by(external_id: "tx:d1").transaction
    assert_equal [ "Contribution", "investment_contribution" ], [ deposit.investment_activity_label, deposit.kind ]
    assert_operator account.opening_anchor_date, :<, Date.new(2026, 1, 10)

    materialize(account)
    assert_equal 1010, balance_on(account, "2026-01-31")
    assert_equal 1020, balance_on(account, "2026-02-15")
  end

  test "a cash portfolio's deposits stay ordinary rows" do
    @stashaway_account.update!(goal_type: "SIMPLE")
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    assert_equal "Depository", account.accountable_type

    process

    deposit = account.entries.find_by!(external_id: "tx:d1").transaction
    assert_nil deposit.investment_activity_label
    assert deposit.standard?
  end

  test "a second import changes nothing" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    before = account.entries.order(:id).pluck(:id, :updated_at, :amount, :date, :name)

    assert_no_difference -> { Entry.count } do
      process
    end

    assert_equal before, account.entries.order(:id).pluck(:id, :updated_at, :amount, :date, :name)
  end

  test "the month-to-date adjustment moves to the latest value day and becomes the month-end one" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process

    travel_to Date.new(2026, 3, 2)
    store_goals(history_through("2026-02-28"))
    process

    returns = account.entries.where(source: "stashaway", external_id: "ret:2026-02")
    assert_equal 1, returns.count
    assert_equal [ Date.new(2026, 2, 28), "Returns (month-end adjustment, 2026-02)" ], [ returns.sole.date, returns.sole.name ]
    assert_equal BigDecimal("-18.5"), returns.sole.amount
    assert_equal 1030, account.reload.balance
  end

  test "a returns row the user categorized still moves to month end with the full amount" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    returns = account.entries.find_by!(external_id: "ret:2026-02")
    returns.transaction.update!(category: @fees)
    returns.mark_user_modified!

    travel_to Date.new(2026, 3, 2)
    store_goals(history_through("2026-02-28"))
    process

    returns.reload
    assert_equal [ Date.new(2026, 2, 28), BigDecimal("-18.5"), "Returns (month-end adjustment, 2026-02)" ], [ returns.date, returns.amount, returns.name ]
    assert_equal @fees, returns.transaction.category
    assert returns.user_modified?
    assert_equal 1030, account.reload.balance
  end

  test "a returns row the user categorized goes with its month when the plan no longer has it" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    returns = account.entries.find_by!(external_id: "ret:2026-02")
    returns.transaction.update!(category: @fees)
    returns.mark_user_modified!

    # StashAway's values now end in January, so February has no row yet.
    store_goals(history_through("2026-01-31"))
    process

    assert_nil account.entries.find_by(external_id: "ret:2026-02")
    assert account.entries.exists?(external_id: "ret:2026-01")
  end

  test "moving the anchor leaves no reconciliation waypoint behind" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process

    travel_to Date.new(2026, 2, 20)
    store_goals(history_through("2026-02-19"))
    process

    assert_empty account.valuations.reconciliation
    assert_equal Date.new(2026, 2, 20), account.current_anchor_date
  end

  test "removes StashAway entries the plan no longer has and leaves every other entry alone" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    manual = create_transaction(account: account, date: Date.new(2026, 1, 20), amount: 7, currency: "SGD", name: "Manual")
    edited = account.entries.find_by!(external_id: "tx:f1")
    edited.update!(name: "Fee I renamed", user_modified: true)

    goals = history_through("2026-02-15")
    goals.first["transactions"].reject! { |item| item["id"].in?(%w[ge1 gf1]) }
    store_goals(goals)
    process

    assert_nil account.entries.find_by(external_id: "tx:e1")
    assert_equal "Fee I renamed", edited.reload.name
    assert manual.reload.persisted?
  end

  test "a deposit the user edited keeps its amount and the month's returns row absorbs the difference" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    deposit = account.entries.find_by!(external_id: "tx:d1")
    deposit.update!(amount: -990, user_modified: true)

    process

    assert_equal BigDecimal("-990"), deposit.reload.amount
    assert_equal BigDecimal("-20"), account.entries.find_by!(external_id: "ret:2026-01").amount
    materialize(account)
    assert_equal 1010, balance_on(account, "2026-01-31")
    assert_equal 1020, balance_on(account, "2026-02-15")
  end

  test "an excluded row the plan no longer has stays and still counts in the month's returns" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    fee = account.entries.find_by!(external_id: "tx:f1")
    fee.update!(excluded: true)

    goals = history_through("2026-02-15")
    goals.first["transactions"].reject! { |item| item["id"] == "gf1" }
    store_goals(goals)
    process

    assert fee.reload.excluded?
    assert_equal BigDecimal("-8.5"), account.entries.find_by!(external_id: "ret:2026-02").amount, "an excluded row is still in the balance"
    materialize(account)
    assert_equal 1010, balance_on(account, "2026-01-31")
  end

  test "a portfolio closed between syncs keeps its rows and books the value that left as a withdrawal" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process

    goals = history_through("2026-02-15")
    goals.first.merge!("state" => "CLOSED", "unavailable" => "closed")
    store_goals(goals)
    result = process

    entries = account.entries.where(source: "stashaway")
    assert_equal %w[ret:2026-01 ret:2026-02 tx:closed:G1 tx:d1 tx:e1 tx:f1], entries.pluck(:external_id).sort
    closing = entries.find_by!(external_id: "tx:closed:G1")
    assert_equal [ Date.new(2026, 2, 16), BigDecimal("1020"), "Withdrawal (portfolio closed)" ], [ closing.date, closing.amount, closing.name ]
    assert_equal "Withdrawal", closing.transaction.investment_activity_label
    assert_equal 0, account.reload.balance
    assert_match(/detail stored last is used/, result.warnings.sole)
  end

  test "an account linked again after an entry from elsewhere keeps the StashAway rows before it" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    create_transaction(account: account, date: Date.new(2026, 2, 1), amount: 5, currency: "SGD", name: "Fee from my statement")
    account.account_providers.destroy_all
    @stashaway_account.reload.link_to!(account.reload)
    assert_equal Date.new(2026, 2, 2), @stashaway_account.reload.import_start_date

    process

    kept = account.entries.where(source: "stashaway", date: ...Date.new(2026, 2, 2)).pluck(:external_id)
    assert_includes kept, "tx:d1", "the deposit an earlier link imported stays"
    assert_includes kept, "ret:2026-01"
  end

  test "a StashAway row without an external id that the user edited stays, and one untouched goes" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    kept = create_transaction(account: account, date: Date.new(2026, 1, 21), amount: 3, currency: "SGD", name: "Edited, no id")
    kept.update!(source: StashawayAccount::SOURCE, external_id: nil, user_modified: true)
    gone = create_transaction(account: account, date: Date.new(2026, 1, 22), amount: 4, currency: "SGD", name: "Untouched, no id")
    gone.update!(source: StashawayAccount::SOURCE, external_id: nil)

    process

    assert Entry.exists?(kept.id)
    assert_not Entry.exists?(gone.id)
  end

  test "a plan without value history anchors a new account on the value stored for its portfolios" do
    goals = history_through("2026-02-15")
    goals.first["performance"] = {}
    store_goals(goals)
    account = link_new_account
    assert_equal 0, account.balance

    result = process

    assert_equal [ 1020, 1020, 1020 ], [ account.reload.balance, account.cash_balance, account.current_anchor_balance ]
    assert_empty account.entries.where(source: "stashaway")
    assert_includes result.warnings, "nothing applied: no SGD value history for any portfolio"
  end

  test "a plan without value history changes nothing" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    process
    before = account.entries.order(:id).pluck(:id, :amount, :date)
    goals = history_through("2026-02-15")
    goals.first["performance"] = {}
    store_goals(goals)

    result = process

    assert_equal before, account.entries.order(:id).pluck(:id, :amount, :date)
    assert_equal 1020, account.reload.balance
    assert_includes result.warnings, "nothing applied: no SGD value history for any portfolio"
  end

  test "a statement row of the same day and amount is claimed instead of duplicated" do
    store_goals(history_through("2026-02-15"))
    account = link_new_account
    copy = create_transaction(account: account, date: Date.new(2026, 1, 10), amount: -1000, currency: "SGD", name: "CSV deposit", source: "csv")
    locked = create_transaction(account: account, date: Date.new(2026, 2, 5), amount: 1, currency: "SGD", name: "Fee from my statement", import_locked: true)

    process

    assert_equal [ "tx:d1", "stashaway", "Deposit" ], [ copy.reload.external_id, copy.source, copy.name ]
    assert_equal [ "tx:f1", "stashaway", "Fee from my statement" ], [ locked.reload.external_id, locked.source, locked.name ]
    assert_equal 5, account.entries.where(source: "stashaway").count
  end

  test "linking an account with statement history starts after it, from its own balance" do
    account = account_with_statement_history
    statement_rows = account.entries.where(source: nil).order(:id).pluck(:id, :updated_at, :amount, :date)

    travel_to Date.new(2026, 4, 1)
    store_goals(goals_appending_to_statements)
    @stashaway_account.link_to!(account)

    assert_equal Date.new(2026, 3, 1), @stashaway_account.import_start_date
    process

    assert_equal [
      "2026-03-05 Deposit -200",
      "2026-03-06 Management fee (Feb 2026) 2",
      "2026-03-31 Returns (month-end adjustment, 2026-03) -58.78"
    ], stashaway_plan_lines(account.entries.where(source: "stashaway").order(:date))
    current_anchor = account.valuations.current_anchor.sole.entry
    assert_equal statement_rows, account.entries.where(source: nil).where.not(id: current_anchor.id).order(:id).pluck(:id, :updated_at, :amount, :date)
    assert_equal 1350, account.reload.balance
    assert_equal BigDecimal("1093.22"), @stashaway_account.reload.import_base

    materialize(account)
    assert_equal BigDecimal("1093.22"), balance_on(account, "2026-02-28"), "the statement history keeps its balances"
    assert_equal 1350, balance_on(account, "2026-03-31")
  end

  test "the append base is fixed by the first import, so a later row after the start does not move it" do
    account = account_with_statement_history
    travel_to Date.new(2026, 4, 1)
    store_goals(goals_appending_to_statements)
    @stashaway_account.link_to!(account)
    process
    create_transaction(account: account, date: Date.new(2026, 3, 20), amount: -100, currency: "SGD", name: "Transfer leg the user created")
    materialize(account)
    assert_equal BigDecimal("993.22"), balance_on(account, "2026-02-28"), "the stored balance before the start now carries the extra row"

    process

    assert_equal BigDecimal("1093.22"), @stashaway_account.reload.import_base
    assert_equal BigDecimal("-58.78"), account.entries.find_by!(external_id: "ret:2026-03").amount
  end

  test "linking before the account's balances are materialized still measures from its own history" do
    account = account_with_statement_history(materialize: false)
    travel_to Date.new(2026, 4, 1)
    store_goals(goals_appending_to_statements)
    @stashaway_account.link_to!(account)
    # The sync that follows a link derives the balances backwards from the
    # cached balance, 0 here, until the first import anchors the account.
    materialize(account)
    assert_equal 0, balance_on(account, "2026-02-28")

    process

    assert_equal BigDecimal("1093.22"), @stashaway_account.reload.import_base
    assert_equal BigDecimal("-58.78"), account.entries.find_by!(external_id: "ret:2026-03").amount
    materialize(account)
    assert_equal BigDecimal("1093.22"), balance_on(account, "2026-02-28")
  end

  test "an account linked without other entries plans the whole history" do
    account = @family.accounts.create!(name: "Fresh", balance: 0, currency: "SGD", accountable: Investment.new)
    @stashaway_account.update!(import_base: 1)

    @stashaway_account.link_to!(account)

    assert_nil @stashaway_account.import_start_date
    assert_nil @stashaway_account.import_base, "a base left by an earlier link is dropped"
  end

  test "an entered opening balance counts as the account's own history" do
    account = @family.accounts.create!(name: "Entered", balance: 500, currency: "SGD", accountable: Investment.new)
    account.entries.create!(date: Date.new(2026, 1, 31), name: "Opening balance", amount: 500, currency: "SGD", entryable: Valuation.new(kind: "opening_anchor"))

    @stashaway_account.link_to!(account)

    assert_equal Date.new(2026, 2, 1), @stashaway_account.import_start_date
  end

  private

    # The first plan test's goal, valued through `last_day`.
    def history_through(last_day)
      [ stashaway_goal("G1",
        transactions: [
          stashaway_row("d1", "2026-01-10", "Deposit", 1000),
          stashaway_row("f1", "2026-02-05", "Fee", -1, description: "2026-01"),
          stashaway_row("e1", "2026-02-08", "Entitlement", 2.5, description: "Dividend received", code: "ABC")
        ],
        nav: { "SGD" => stashaway_daily("2026-01-10", last_day) { |d| d <= "2026-01-30" ? 1000 : (d == "2026-01-31" ? 1010 : (d <= "2026-02-15" ? 1020 : 1030)) } }) ]
    end

    # An account with its own statement rows: a 1000 deposit in January and
    # 93.22 of returns on Feb 28, so its own balance on Feb 28 is 1093.22.
    def account_with_statement_history(materialize: true)
      account = @family.accounts.create!(name: "StashAway General", balance: 0, currency: "SGD", accountable: Investment.new)
      account.entries.create!(date: Date.new(2025, 12, 31), name: "Opening balance", amount: 0, currency: "SGD", entryable: Valuation.new(kind: "opening_anchor"))
      create_transaction(account: account, date: Date.new(2026, 1, 10), amount: -1000, currency: "SGD", name: "Statement deposit")
      create_transaction(account: account, date: Date.new(2026, 2, 28), amount: BigDecimal("-93.22"), currency: "SGD", name: "Statement returns")
      materialize(account, strategy: :forward) if materialize
      account
    end

    # StashAway's side of that account: worth 1100 through February, where
    # the statements say 1093.22, and 1350 at the end of March.
    def goals_appending_to_statements
      [ stashaway_goal("G1",
        transactions: [
          stashaway_row("d0", "2026-01-10", "Deposit", 1000),
          stashaway_row("d1", "2026-03-05", "Deposit", 200),
          stashaway_row("f1", "2026-03-06", "Fee", -2, description: "2026-02")
        ],
        nav: { "SGD" => stashaway_daily("2026-01-10", "2026-03-31") { |d| d < "2026-03-01" ? 1100 : 1350 } }) ]
    end

    def store_goals(goals)
      @stashaway_account.update!(raw_goals_payload: goals)
    end

    def link_new_account
      Account.create_from_stashaway_account(@stashaway_account).tap { |account| @stashaway_account.link_to!(account) }
    end

    def process
      StashawayAccount::Processor.new(@stashaway_account.reload).process
    end

    def materialize(account, strategy: :reverse)
      Balance::Materializer.new(account.reload, strategy: strategy).materialize_balances
    end

    def balance_on(account, date)
      account.balances.find_by!(date: Date.parse(date)).balance
    end
end
