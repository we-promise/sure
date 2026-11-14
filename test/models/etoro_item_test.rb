require "test_helper"

class EtoroItemTest < ActiveSupport::TestCase
  include SyncableInterfaceTest

  setup do
    @item = @syncable = etoro_items(:configured_item)
  end

  test "needs both keys to be configured" do
    assert @item.credentials_configured?

    @item.user_key = ""
    assert_not @item.credentials_configured?
  end

  test "process_accounts lets go of the securities its accounts left, with their rows of zero units" do
    account = accounts(:investment)
    etoro_accounts(:main_account).ensure_account_provider!(account)
    EtoroAccount::Processor.any_instance.stubs(:process).returns({ holdings: 0, failed_records: 0 })
    left = Security.create!(ticker: "LEFT", exchange_operating_mic: "XNAS", offline: true)
    Security::Price.create!(security: left, date: Date.current, price: 10, currency: "USD")
    held = Security.create!(ticker: "HELD", exchange_operating_mic: "XNAS", offline: true)
    shared = Security.create!(ticker: "SHRD", exchange_operating_mic: "XNAS", offline: true)
    row = ->(security, acct, qty, date = Date.current) { Holding.create!(account: acct, security: security, date: date, qty: qty, price: 10, amount: qty * 10, currency: "USD") }
    row.call(left, account, 0, Date.current - 1)
    row.call(left, account, 0)
    row.call(held, account, 0, Date.current - 1)
    row.call(held, account, 3)
    row.call(shared, account, 0)
    row.call(shared, accounts(:crypto), 0)

    @item.process_accounts

    assert_not Security.exists?(left.id)
    assert_empty Holding.where(security_id: left.id)
    assert_empty Security::Price.where(security_id: left.id)
    assert Security.exists?(held.id)
    assert_equal 2, Holding.where(security_id: held.id).count
    assert Security.exists?(shared.id), "a row of zero units in another account keeps the security"
    assert_equal 2, Holding.where(security_id: shared.id).count
  end

  test "process_accounts keeps a security a user moved a holding away from" do
    account = accounts(:investment)
    etoro_accounts(:main_account).ensure_account_provider!(account)
    EtoroAccount::Processor.any_instance.stubs(:process).returns({ holdings: 0, failed_records: 0 })
    reported = Security.create!(ticker: "RPTD", exchange_operating_mic: "XNAS", offline: true)
    Holding.create!(account: account, security: reported, date: Date.current - 1, qty: 0, price: 10, amount: 0, currency: "USD")
    chosen = Security.create!(ticker: "CHSN", exchange_operating_mic: "XNAS", offline: true)
    Holding.create!(account: account, security: chosen, provider_security: reported, security_locked: true, date: Date.current, qty: 2, price: 10, amount: 20, currency: "USD")

    @item.process_accounts

    assert Security.exists?(reported.id)
  end

  test "process_accounts skips accounts that are disabled or being deleted" do
    account = accounts(:investment)
    etoro_accounts(:main_account).ensure_account_provider!(account)
    account.disable!
    EtoroAccount::Processor.any_instance.expects(:process).never

    assert_empty @item.process_accounts
  end

  # Deleting the connection waits only for a sync under five minutes old
  # (Sync::VISIBLE_FOR). A pass running longer reads each account's link
  # afresh as it reaches it, so it leaves alone the accounts unlinked
  # meanwhile.
  test "process_accounts leaves alone an account unlinked while the pass runs" do
    main = etoro_accounts(:main_account)
    main.ensure_account_provider!(accounts(:investment))
    copy = main.copy_accounts.create!(
      etoro_item: @item, mirror_id: 7, etoro_account_id: "#{main.etoro_account_id}-copy-7",
      name: "eToro copy: trader7", currency: "USD", display_mode: :copies
    )
    copy.ensure_account_provider!(Account.create_from_etoro_account(copy))

    item = @item
    unlinking = Object.new
    unlinking.define_singleton_method(:process) { item.unlink_all!; {} }
    EtoroAccount::Processor.expects(:new).once.returns(unlinking)

    assert_equal [ main.id ], @item.process_accounts.map { |result| result[:etoro_account_id] }
  end

  test "unlink_all! detaches the account and keeps its holdings" do
    account = accounts(:investment)
    link = etoro_accounts(:main_account).ensure_account_provider!(account)
    holding = Holding.create!(
      account: account,
      security: securities(:msft),
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider_id: link.id
    )

    @item.unlink_all!(dry_run: false)

    assert_not AccountProvider.exists?(provider_type: "EtoroAccount")
    assert_nil holding.reload.account_provider_id
    assert Account.exists?(account.id)
  end

  test "unlink_all! changes nothing on a dry run" do
    link = etoro_accounts(:main_account).ensure_account_provider!(accounts(:investment))

    results = @item.unlink_all!(dry_run: true)

    assert_equal [ link.id ], results.flat_map { |result| result[:provider_link_ids] }
    assert AccountProvider.exists?(link.id)
  end

  test "copies count as recorded once Sure has recorded a copy-trading portfolio, not only the positions the user opened" do
    main = etoro_accounts(:main_account)
    main.portfolio_snapshots.create!(mirror_id: EtoroPortfolioSnapshot::OWN_POSITIONS, date: Date.current, total: 100, cash: 10)
    assert_not @item.copies_recorded?

    main.portfolio_snapshots.create!(mirror_id: 7, date: Date.current, total: 50, cash: 5, username: "trader")
    assert @item.copies_recorded?
    assert_not etoro_items(:pending_setup_item).copies_recorded?
  end

  test "deleting the connection deletes what Sure recorded of its copies" do
    etoro_accounts(:main_account).portfolio_snapshots.create!(mirror_id: 7, date: Date.current, total: 50, cash: 5, username: "trader")

    @item.destroy!

    assert_not EtoroPortfolioSnapshot.exists?
  end

  test "deleting the connection hands the securities eToro priced back to Sure without eToro's prices" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    @item.update!(raw_instruments_payload: { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } })

    @item.destroy!

    assert_equal [ true, nil ], [ priced.reload.offline?, priced.offline_reason ]
    assert_empty priced.prices
  end

  test "deleting the connection syncs again the accounts valued at eToro's prices" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    @item.update!(raw_instruments_payload: { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } })
    holder = accounts(:investment)
    holder.holdings.create!(security: priced, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")

    assert_difference -> { holder.syncs.count }, 1 do
      @item.destroy!
    end
  end

  test "deleting the connection leaves the prices another connection linked to an account gives a security" do
    priced = Security.create!(ticker: "ACME", offline: true, offline_reason: EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON)
    Security::Price.create!(security: priced, date: Date.current, price: 10, currency: "USD")
    instruments = { "3001" => { "symbol" => "ACME", "price_history" => { "security_id" => priced.id, "currency" => "USD", "written_from" => Date.current.iso8601 } } }
    @item.update!(raw_instruments_payload: instruments)
    newer = etoro_items(:pending_setup_item)
    newer.update!(raw_instruments_payload: instruments)
    newer.etoro_accounts.create!(name: "eToro", etoro_account_id: "etoro_trading_2", currency: "USD").ensure_account_provider!(accounts(:investment))

    @item.destroy!

    assert_equal EtoroAccount::PriceHistoryProcessor::OFFLINE_REASON, priced.reload.offline_reason
    assert_equal 1, priced.prices.count
  end
end
