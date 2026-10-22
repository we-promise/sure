require "test_helper"

RakeTaskTestHelper.load_task("snaptrade:repair_split_securities", "snaptrade")

# A SnapTrade position whose holdings and trades sit on two Security rows of
# the same ticker, the state left behind by the ticker-only lookup that
# #3999 replaced. Row A is the one SnapTrade created (exchange in
# exchange_mic); row B is the one a CSV import or ticker search created
# (exchange in exchange_operating_mic). A is the older row, so the oldest-row
# and preferred-row fallbacks both pick A; only the held position points at B.
class SnaptradeAccount::SplitSecurityRepairTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    RakeTaskTestHelper.prepare("snaptrade:repair_split_securities")

    @family = families(:dylan_family)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)
    @account = @family.accounts.create!(
      name: "Stake US",
      balance: 6000,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new
    )
    @snaptrade_account.ensure_account_provider!(@account)
    @provider_id = @snaptrade_account.reload.account_provider.id

    @row_a = Security.create!(ticker: "SPLT", name: "Split Co", exchange_mic: "XNYS", created_at: 2.days.ago)
    @row_b = Security.create!(ticker: "SPLT", name: "Split Co", exchange_operating_mic: "XNYS", created_at: 1.day.ago)
  end

  test "repair moves the duplicate row's trades onto the held row and restores avg_cost" do
    holding = seed_observed_split

    assert_nil holding.avg_cost, "precondition: the split hides the trades from the holding"

    result = repair!.sole

    assert_equal Money.new(150, "USD"), holding.reload.avg_cost
    assert_equal @row_b.id, holding.security_id
    assert_equal 2, result.trades_moved
  end

  # Report caches key on Family#entries_cache_version (the latest entry
  # updated_at). Moving trades with update_all touches no entry, so a figure
  # cached before the repair would keep grouping the trades under the old row.
  test "a live repair moves the family's entries cache version" do
    seed_observed_split
    before = @family.reload.entries_cache_version

    travel 1.minute do
      repair!
    end

    assert_not_equal before, @family.reload.entries_cache_version
  end

  test "repair resolves to the row resolve_security keeps picking" do
    seed_observed_split
    resolver = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    assert_equal @row_b, resolver.send(:resolve_security, "SPLT", {}, account: @account, account_provider_id: @provider_id),
      "precondition: sync resolves the ticker to the held row, not the older one"

    result = repair!.sole

    assert_equal @row_b.id, result.target_id
    assert_equal :held, result.target_source
    assert_equal 2, @account.trades.where(security_id: @row_b.id).count
    assert_equal 0, @account.trades.where(security_id: @row_a.id).count
    assert_equal 0, @account.holdings.where(security_id: @row_a.id).count
    assert_equal @row_b, resolver.send(:resolve_security, "SPLT", {}, account: @account.reload, account_provider_id: @provider_id)
  end

  test "repair handles a duplicate row that has trades but no holding" do
    create_trade(@row_a, account: @account, qty: 10, date: 20.days.ago.to_date, price: 100)
    create_trade(@row_a, account: @account, qty: 10, date: 10.days.ago.to_date, price: 200)
    create_trade(@row_b, account: @account, qty: 5, date: 5.days.ago.to_date, price: 300)
    assert_equal 0, @account.holdings.count, "precondition: no holding names a target"

    result = repair!.sole

    assert_equal @row_a.id, result.target_id
    assert_equal :most_trades, result.target_source
    assert_equal 1, result.trades_moved
    assert_equal 3, @account.trades.where(security_id: @row_a.id).count
    assert_equal 0, @account.trades.where(security_id: @row_b.id).count
  end

  test "repair keeps the target holding on a same-day collision without summing qty" do
    seed_observed_split
    yesterday = 1.day.ago.to_date
    snaptrade_holding(@row_b, date: yesterday, qty: 20)
    duplicate = snaptrade_holding(@row_a, date: yesterday, qty: 20)

    result = repair!.sole

    assert_equal [ 20 ], @account.holdings.where(security_id: @row_b.id, date: yesterday).pluck(:qty).map(&:to_i)
    assert_not Holding.exists?(duplicate.id)
    assert_equal 1, result.holdings_dropped
  end

  # A calculated row is rebuilt from the trades by the re-materialization; a
  # SnapTrade snapshot is the only record of that day's provider cost basis.
  test "a calculated target row gives way to the SnapTrade snapshot on a same-day collision" do
    seed_observed_split
    yesterday = 1.day.ago.to_date
    calculated = @account.holdings.create!(security: @row_b, date: yesterday, qty: 20, price: 300, amount: 6000, currency: "USD")
    snapshot = snaptrade_holding(@row_a, date: yesterday, qty: 20)
    snapshot.update!(cost_basis: 123, cost_basis_source: "provider")

    result = repair!.sole

    kept = @account.holdings.find_by!(security_id: @row_b.id, date: yesterday, currency: "USD")
    assert_equal snapshot.id, kept.id
    assert_equal @provider_id, kept.account_provider_id
    assert_equal 123, kept.cost_basis.to_i
    assert_not Holding.exists?(calculated.id)
    assert_equal [ 1, 1 ], [ result.holdings_moved, result.holdings_replaced ]
  end

  test "a live repair re-materializes the account for the target rows" do
    seed_observed_split
    materializer = mock("materializer")
    materializer.expects(:materialize_balances).once
    Balance::Materializer.expects(:new)
      .with(@account, strategy: :reverse, security_ids: [ @row_b.id ])
      .returns(materializer)

    repair!
  end

  test "a failure while re-materializing rolls back the moved rows" do
    holding = seed_observed_split
    before = account_state
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(StandardError, "boom")

    assert_raises(StandardError) { repair! }

    assert_equal before, account_state
    assert_nil holding.reload.avg_cost
  end

  test "dry run changes nothing" do
    holding = seed_observed_split
    before = account_state

    result = SnaptradeAccount::SplitSecurityRepair.new(@account).run.sole

    assert_equal 2, result.trades_moved, "the dry run still reports what it would move"
    assert_equal before, account_state
    assert_nil holding.reload.avg_cost
  end

  test "another account's holdings and trades on the duplicate row are untouched" do
    seed_observed_split
    other = @family.accounts.create!(name: "Other", balance: 1000, cash_balance: 0, currency: "USD", accountable: Investment.new)
    create_trade(@row_a, account: other, qty: 3, date: 4.days.ago.to_date, price: 100)
    other_holding = other.holdings.create!(security: @row_a, date: Date.current, qty: 3, price: 100, amount: 300, currency: "USD")

    repair!

    assert_equal [ @row_a.id ], other.trades.pluck(:security_id)
    assert_equal @row_a.id, other_holding.reload.security_id
  end

  test "another provider's holding on the same account is untouched" do
    seed_observed_split
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    other_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    foreign = @account.holdings.create!(security: @row_a, date: 3.days.ago.to_date, qty: 7, price: 100, amount: 700,
                                        currency: "USD", account_provider_id: other_provider.id)

    repair!

    assert_equal @row_a.id, foreign.reload.security_id
    assert_equal 7, foreign.qty.to_i
  end

  test "a non-SnapTrade account is skipped" do
    manual = @family.accounts.create!(name: "Manual", balance: 6000, cash_balance: 0, currency: "USD", accountable: Investment.new)
    create_trade(@row_a, account: manual, qty: 10, date: 20.days.ago.to_date, price: 100)
    manual.holdings.create!(security: @row_b, date: Date.current, qty: 10, price: 300, amount: 3000, currency: "USD")
    before = [ manual.trades.pluck(:security_id), manual.holdings.pluck(:security_id) ]

    assert_empty SnaptradeAccount::SplitSecurityRepair.new(manual, dry_run: false).run
    assert_equal before, [ manual.trades.pluck(:security_id), manual.holdings.pluck(:security_id) ]
    assert_not_includes SnaptradeAccount::SplitSecurityRepair.accounts, manual
    assert_includes SnaptradeAccount::SplitSecurityRepair.accounts, @account
  end

  test "a ticker with one row is a no-op" do
    create_trade(@row_b, account: @account, qty: 10, date: 20.days.ago.to_date, price: 100)
    holding = snaptrade_holding(@row_b, date: Date.current, qty: 10)
    before = account_state

    assert_empty repair!
    assert_equal before, account_state
    assert_equal Money.new(100, "USD"), holding.reload.avg_cost
  end

  test "a different ticker is unaffected" do
    seed_observed_split
    other_ticker = Security.create!(ticker: "OTHR", name: "Other Co", exchange_mic: "XNYS")
    create_trade(other_ticker, account: @account, qty: 4, date: 6.days.ago.to_date, price: 50)
    other_holding = snaptrade_holding(other_ticker, date: Date.current, qty: 4)

    results = repair!

    assert_equal [ "SPLT" ], results.map(&:ticker)
    assert_equal [ other_ticker.id ], @account.trades.joins(:security).where(securities: { ticker: "OTHR" }).pluck(:security_id)
    assert_equal other_ticker.id, other_holding.reload.security_id
  end

  test "no Security row is destroyed and no price is moved" do
    seed_observed_split
    price_a = Security::Price.create!(security: @row_a, date: 12.days.ago.to_date, price: 190, currency: "USD")
    price_b = Security::Price.create!(security: @row_b, date: 11.days.ago.to_date, price: 195, currency: "USD")

    # Row A's price is a gap on B; allowed here, since the point is what moves.
    assert_no_difference -> { Security.count } do
      repair!(allow_price_gaps: true)
    end

    assert Security.exists?(@row_a.id)
    assert_equal @row_a.id, price_a.reload.security_id
    assert_equal @row_b.id, price_b.reload.security_id
  end

  test "moved holdings are not security_locked and carry no provider_security_id" do
    seed_observed_split
    moved = snaptrade_holding(@row_a, date: 5.days.ago.to_date, qty: 20)

    result = repair!.sole

    moved.reload
    assert_equal @row_b.id, moved.security_id
    assert_not moved.security_locked?
    assert_nil moved.provider_security_id
    assert_equal 1, result.holdings_moved
  end

  test "a live repair that would leave price gaps is refused and writes nothing" do
    holding = seed_observed_split
    Security::Price.create!(security: @row_a, date: 15.days.ago.to_date, price: 180, currency: "USD")
    before = account_state

    error = assert_raises(SnaptradeAccount::SplitSecurityRepair::PriceGapsRefused) { repair! }

    assert_match(/SPLT: 1 date/, error.message)
    assert_equal before, account_state
    assert_nil holding.reload.avg_cost
  end

  # The observed split has the held row carrying the prices. Here the held
  # row has none and the other row has them all, so the moved history can
  # only be priced once market data fills the held row; the repair says so.
  test "a split in the opposite direction keeps today's value and reports the price gap" do
    holding = seed_observed_split
    gap_dates = [ 15.days.ago.to_date, 8.days.ago.to_date ]
    gap_dates.each { |date| Security::Price.create!(security: @row_a, date: date, price: 180, currency: "USD") }
    shared_date = 12.days.ago.to_date
    Security::Price.create!(security: @row_a, date: shared_date, price: 185, currency: "USD")
    Security::Price.create!(security: @row_b, date: shared_date, price: 185, currency: "USD")
    # Before the account's first entry, so outside its history.
    Security::Price.create!(security: @row_a, date: 40.days.ago.to_date, price: 150, currency: "USD")
    prices_before = Security::Price.where(security_id: [ @row_a.id, @row_b.id ]).order(:id).pluck(:id, :security_id)

    result = repair!(allow_price_gaps: true).sole

    holding.reload
    assert_equal [ 20, 6000 ], [ holding.qty.to_i, holding.amount.to_i ]
    assert_equal Date.current, holding.date
    assert_equal prices_before, Security::Price.where(security_id: [ @row_a.id, @row_b.id ]).order(:id).pluck(:id, :security_id)
    assert_equal gap_dates.sort, result.price_gap_dates
  end

  test "the rake task is a dry run unless DRY_RUN is false" do
    holding = seed_observed_split

    output, = with_env("DRY_RUN" => nil) do
      capture_io { Rake::Task["snaptrade:repair_split_securities"].invoke(@account.id) }
    end
    assert_match(/DRY RUN/, output)
    assert_match(/SPLT/, output)
    assert_nil holding.reload.avg_cost

    Rake::Task["snaptrade:repair_split_securities"].reenable
    with_env("DRY_RUN" => "false") do
      capture_io { Rake::Task["snaptrade:repair_split_securities"].invoke(@account.id) }
    end
    assert_equal Money.new(150, "USD"), holding.reload.avg_cost
  end

  test "the rake task refuses a live repair with price gaps unless ALLOW_PRICE_GAPS names one account" do
    holding = seed_observed_split
    Security::Price.create!(security: @row_a, date: 15.days.ago.to_date, price: 180, currency: "USD")
    task = Rake::Task["snaptrade:repair_split_securities"]

    output, = with_env("DRY_RUN" => "false", "ALLOW_PRICE_GAPS" => nil) { capture_io { task.invoke(@account.id) } }
    assert_match(/refused, nothing written/, output)
    assert_nil holding.reload.avg_cost

    task.reenable
    output, = with_env("DRY_RUN" => "false", "ALLOW_PRICE_GAPS" => "true") { capture_io { task.invoke } }
    assert_match(/needs an account id/, output)
    assert_nil holding.reload.avg_cost

    task.reenable
    with_env("DRY_RUN" => "false", "ALLOW_PRICE_GAPS" => "true") { capture_io { task.invoke(@account.id) } }
    assert_equal Money.new(150, "USD"), holding.reload.avg_cost
  end

  # Security uniqueness is scoped to exchange_operating_mic, so one ticker can
  # be two real listings. Holding both is not the split this repairs.
  test "a ticker held on two different exchanges is left alone and reported" do
    shop_us = Security.create!(ticker: "SHOP", name: "Shopify", exchange_operating_mic: "XNYS")
    shop_ca = Security.create!(ticker: "SHOP", name: "Shopify", exchange_operating_mic: "XTSE")
    create_trade(shop_us, account: @account, qty: 5, date: 9.days.ago.to_date, price: 100)
    create_trade(shop_ca, account: @account, qty: 7, date: 8.days.ago.to_date, price: 130)
    snaptrade_holding(shop_us, date: Date.current, qty: 5)
    snaptrade_holding(shop_ca, date: Date.current, qty: 7)
    before = account_state
    repair = SnaptradeAccount::SplitSecurityRepair.new(@account, dry_run: false)

    assert_empty repair.run
    assert_equal before, account_state
    assert_equal({ "SHOP" => [ [ shop_us.id, "XNYS" ], [ shop_ca.id, "XTSE" ] ].sort }, repair.conflicts)
  end

  test "a SnapTrade row on another exchange than the second row is not merged" do
    seed_observed_split
    @row_a.update_columns(exchange_mic: "XTSE")
    before = account_state
    repair = SnaptradeAccount::SplitSecurityRepair.new(@account, dry_run: false)

    assert_empty repair.run
    assert_equal before, account_state
    assert_equal [ "SPLT" ], repair.conflicts.keys
  end

  test "a row with no exchange at all is merged with the row that has one" do
    holding = seed_observed_split
    @row_a.update_columns(exchange_mic: nil)

    repair = SnaptradeAccount::SplitSecurityRepair.new(@account, dry_run: false)
    repair.run

    assert_equal Money.new(150, "USD"), holding.reload.avg_cost
    assert_empty repair.conflicts
  end

  # The holding calculators load splits by security_id, so trades moved onto
  # a target that lacks the source's split would replay without it.
  test "a live repair is refused when the source row has a split the target lacks" do
    holding = seed_observed_split
    @row_a.splits.create!(ex_date: 15.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    before = account_state

    error = assert_raises(SnaptradeAccount::SplitSecurityRepair::SplitHistoryRefused) { repair!(allow_price_gaps: true) }

    assert_match(/SPLT: #{15.days.ago.to_date.iso8601}/, error.message)
    assert_equal before, account_state
    assert_nil holding.reload.avg_cost
  end

  test "a dry run reports the source splits the target lacks" do
    seed_observed_split
    ex_date = 15.days.ago.to_date
    @row_a.splits.create!(ex_date: ex_date, numerator: 2, denominator: 1, source: "manual")
    @row_a.splits.create!(ex_date: 5.days.ago.to_date, numerator: 3, denominator: 1, source: "manual")
    # Same date and ratio on the target: matched, so not reported.
    @row_b.splits.create!(ex_date: 5.days.ago.to_date, numerator: 3, denominator: 1, source: "manual")

    result = SnaptradeAccount::SplitSecurityRepair.new(@account).run.sole

    assert_equal [ ex_date ], result.unmatched_split_dates
  end

  test "a source split with a different ratio on the target is unmatched" do
    seed_observed_split
    ex_date = 15.days.ago.to_date
    @row_a.splits.create!(ex_date: ex_date, numerator: 2, denominator: 1, source: "manual")
    @row_b.splits.create!(ex_date: ex_date, numerator: 3, denominator: 1, source: "manual")

    assert_equal [ ex_date ], SnaptradeAccount::SplitSecurityRepair.new(@account).run.sole.unmatched_split_dates
  end

  test "a live repair goes ahead when the target carries the same split" do
    holding = seed_observed_split
    [ @row_a, @row_b ].each do |row|
      row.splits.create!(ex_date: 15.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    end

    result = repair!.sole

    assert_empty result.unmatched_split_dates
    assert_equal @row_b.id, holding.reload.security_id
    assert_equal 0, @account.trades.where(security_id: @row_a.id).count
  end

  test "a failed live repair is recorded in the debug log" do
    seed_observed_split
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(StandardError, "boom")

    assert_difference -> { DebugLogEntry.count }, 1 do
      assert_raises(StandardError) { repair! }
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "provider_sync_error", "error", "snaptrade" ], [ entry.category, entry.level, entry.provider_key ]
    assert_equal [ @account.id, @family.id, @provider_id ], [ entry.account_id, entry.family_id, entry.account_provider_id ]
    assert_equal "StandardError", entry.metadata["error_class"]
    assert_match(/boom/, entry.message)
  end

  test "a refusal is not recorded in the debug log" do
    seed_observed_split
    Security::Price.create!(security: @row_a, date: 15.days.ago.to_date, price: 180, currency: "USD")

    assert_no_difference -> { DebugLogEntry.count } do
      assert_raises(SnaptradeAccount::SplitSecurityRepair::PriceGapsRefused) { repair! }
    end
  end

  test "the rake task exits non-zero when an account fails" do
    seed_observed_split
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(StandardError, "boom")
    SnaptradeAccount::SplitSecurityRepair.stubs(:accounts).returns(Account.where(id: @account.id))

    output, error = invoke_task_expecting_exit("DRY_RUN" => "false")

    assert_not error.success?
    assert_match(/Account #{@account.id}: failed, rolled back: StandardError: boom/, output)
    assert_equal [ @row_a.id ], @account.trades.distinct.pluck(:security_id), "the failed account rolled back"
  end

  # The repair's transaction has committed by the time the task reports on
  # it, so a failure while reporting must not claim a rollback.
  test "a failure while reporting a live repair does not claim a rollback" do
    holding = seed_observed_split
    SnaptradeAccount::SplitSecurityRepair.stubs(:accounts).returns(Account.where(id: @account.id))
    SnaptradeAccount::SplitSecurityRepair.any_instance.stubs(:conflicts).raises(StandardError, "report boom")

    output, error = invoke_task_expecting_exit("DRY_RUN" => "false")

    assert_not error.success?
    assert_equal Money.new(150, "USD"), holding.reload.avg_cost, "the repair committed before reporting failed"
    assert_match(/Account #{@account.id}: repair applied, but reporting failed: StandardError: report boom/, output)
    assert_no_match(/rolled back/, output)
  end

  test "a failure while reporting a dry run says nothing was written" do
    holding = seed_observed_split
    SnaptradeAccount::SplitSecurityRepair.stubs(:accounts).returns(Account.where(id: @account.id))
    SnaptradeAccount::SplitSecurityRepair.any_instance.stubs(:conflicts).raises(StandardError, "report boom")

    output, error = invoke_task_expecting_exit("DRY_RUN" => nil)

    assert_not error.success?
    assert_nil holding.reload.avg_cost
    assert_match(/Account #{@account.id}: reporting failed, nothing written: StandardError: report boom/, output)
    assert_no_match(/rolled back/, output)
  end

  test "the rake dry run names each row's exchange and the conflicting tickers" do
    seed_observed_split
    Security.create!(ticker: "SHOP", name: "Shopify", exchange_operating_mic: "XNYS").tap do |row|
      create_trade(row, account: @account, qty: 5, date: 9.days.ago.to_date, price: 100)
    end
    Security.create!(ticker: "SHOP", name: "Shopify", exchange_operating_mic: "XTSE").tap do |row|
      create_trade(row, account: @account, qty: 7, date: 8.days.ago.to_date, price: 130)
    end

    output, = with_env("DRY_RUN" => nil) do
      capture_io { Rake::Task["snaptrade:repair_split_securities"].invoke(@account.id) }
    end

    assert_match(/target #{@row_b.id} \(XNYS, Split Co\)/, output)
    assert_match(/#{@row_a.id} \(XNYS, Split Co\)/, output)
    assert_match(/SHOP: skipped, rows on different exchanges/, output)
  end

  private
    # Runs the task for every account and returns its stdout and stderr
    # together, with the SystemExit its abort raises.
    def invoke_task_expecting_exit(env)
      original_stdout, original_stderr = $stdout, $stderr
      $stdout = $stderr = StringIO.new
      error = assert_raises(SystemExit) do
        with_env(env) { Rake::Task["snaptrade:repair_split_securities"].invoke }
      end
      [ $stdout.string, error ]
    ensure
      $stdout, $stderr = original_stdout, original_stderr
    end


    def repair!(allow_price_gaps: false)
      SnaptradeAccount::SplitSecurityRepair.new(@account, dry_run: false, allow_price_gaps: allow_price_gaps).run
    end

    # The #3988 state: buys on A, the current provider holding
    # on B with an unknown (zero) provider cost basis.
    def seed_observed_split
      create_trade(@row_a, account: @account, qty: 10, date: 20.days.ago.to_date, price: 100)
      create_trade(@row_a, account: @account, qty: 10, date: 10.days.ago.to_date, price: 200)
      holding = snaptrade_holding(@row_b, date: Date.current, qty: 20)
      holding.update!(cost_basis: 0, cost_basis_source: "provider")
      holding
    end

    def snaptrade_holding(security, date:, qty:)
      @account.holdings.create!(
        security: security,
        date: date,
        qty: qty,
        price: 300,
        amount: qty * 300,
        currency: "USD",
        account_provider_id: @provider_id
      )
    end

    def account_state
      [
        @account.trades.order(:id).pluck(:id, :security_id),
        @account.holdings.order(:id).pluck(:id, :security_id, :qty, :updated_at),
        @account.balances.count
      ]
    end

    def with_env(vars)
      saved = vars.keys.index_with { |key| ENV[key] }
      vars.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
end
