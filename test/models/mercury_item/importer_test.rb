# frozen_string_literal: true

require "test_helper"

class MercuryItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item   = MercuryItem.create!(family: @family, name: "Mercury", token: "tok")
    @provider = mock
    @provider.stubs(:get_accounts).returns({ accounts: [] })
    @provider.stubs(:get_account_transactions).returns({ transactions: [] })
  end

  # ---------------------------------------------------------------------------
  # account discovery
  # ---------------------------------------------------------------------------

  test "creates unlinked mercury_account records for newly discovered accounts" do
    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_001", "Business Checking") ] })

    assert_difference "@item.mercury_accounts.count", 1 do
      run_import
    end

    acct = @item.mercury_accounts.find_by(account_id: "acc_001")
    assert acct
    assert_equal "Business Checking", acct.name
    assert_equal "USD", acct.currency
  end

  test "does not duplicate existing unlinked account records on re-import" do
    @item.mercury_accounts.create!(name: "Existing", account_id: "acc_001", currency: "USD")
    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_001", "Business Checking") ] })

    assert_no_difference "@item.mercury_accounts.count" do
      run_import
    end
  end

  test "updates current_balance on linked accounts" do
    account, mercury_account = create_linked_account("acc_balance")
    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_balance", "Checking", balance: 5_000.0) ] })
    @provider.stubs(:get_account_transactions).with("acc_balance", anything).returns({ transactions: [] })

    run_import

    assert_in_delta 5_000.0, mercury_account.reload.current_balance, 0.01
  end

  # ---------------------------------------------------------------------------
  # transaction deduplication
  # ---------------------------------------------------------------------------

  test "appends new transactions and skips duplicate ids" do
    _account, mercury_account = create_linked_account("acc_dedup",
      raw_transactions: [ tx_payload("tx_old") ])

    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_dedup", "Checking") ] })
    @provider.stubs(:get_account_transactions).with("acc_dedup", anything).returns({
      transactions: [ tx_payload("tx_old"), tx_payload("tx_new") ]
    })

    run_import

    ids = mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
    assert_includes ids, "tx_old"
    assert_includes ids, "tx_new"
    assert_equal 2, ids.uniq.size
  end

  # ---------------------------------------------------------------------------
  # paging
  # ---------------------------------------------------------------------------

  test "fetches every page of an account's transactions" do
    _account, mercury_account = create_linked_account("acc_pages")
    use_paging_provider("acc_pages")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    expect_page("acc_pages", offset: 0, limit: 2, ids: %w[tx_1 tx_2])
    expect_page("acc_pages", offset: 2, limit: 2, ids: %w[tx_3 tx_4])
    expect_page("acc_pages", offset: 4, limit: 2, ids: %w[tx_5])

    result = run_import

    assert_equal 5, result[:transactions_imported]
    assert_equal %w[tx_1 tx_2 tx_3 tx_4 tx_5], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "stores a transaction repeated across pages once" do
    _account, mercury_account = create_linked_account("acc_repeat")
    use_paging_provider("acc_repeat")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    expect_page("acc_repeat", offset: 0, limit: 2, ids: %w[tx_1 tx_2])
    expect_page("acc_repeat", offset: 2, limit: 2, ids: %w[tx_2])

    run_import

    assert_equal %w[tx_1 tx_2], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "a full page followed by an empty one stops after the empty page" do
    _account, mercury_account = create_linked_account("acc_full")
    use_paging_provider("acc_full")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    expect_page("acc_full", offset: 0, limit: 2, ids: %w[tx_1 tx_2])
    expect_page("acc_full", offset: 2, limit: 2, ids: [])

    run_import

    assert_equal %w[tx_1 tx_2], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "a short first page makes one request at the documented page size" do
    create_linked_account("acc_short")
    use_paging_provider("acc_short")
    expect_page("acc_short", offset: 0, limit: 1000, ids: %w[tx_1])

    assert_equal 1, run_import[:transactions_imported]
  end

  test "a failed later page leaves the stored transactions unchanged" do
    _account, mercury_account = create_linked_account("acc_fail", raw_transactions: [ tx_payload("tx_old") ])
    use_paging_provider("acc_fail")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    expect_page("acc_fail", offset: 0, limit: 2, ids: %w[tx_1 tx_2])
    @provider.expects(:get_account_transactions).with("acc_fail", has_entries(offset: 2, limit: 2))
             .raises(Provider::Mercury::MercuryError.new("Rate limited", :rate_limited))

    result = run_import

    assert_not result[:success]
    assert_equal 1, result[:transactions_failed]
    assert_equal %w[tx_old], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "a later page that is not a Hash leaves the stored transactions unchanged" do
    _account, mercury_account = create_linked_account("acc_bad_page", raw_transactions: [ tx_payload("tx_old") ])
    use_paging_provider("acc_bad_page")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    expect_page("acc_bad_page", offset: 0, limit: 2, ids: %w[tx_1 tx_2])
    @provider.expects(:get_account_transactions).with("acc_bad_page", has_entries(offset: 2, limit: 2)).returns("<html>")

    result = run_import

    assert_not result[:success]
    assert_equal 1, result[:transactions_failed]
    assert_equal %w[tx_old], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  test "paging stops at the page cap when every page is full of new transactions" do
    _account, mercury_account = create_linked_account("acc_runaway")
    use_paging_provider("acc_runaway")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(1)
    pages = (1..MercuryItem::Importer::MAX_TRANSACTION_PAGES).map { |page| { transactions: [ tx_payload("tx_#{page}") ] } }
    @provider.expects(:get_account_transactions).with("acc_runaway", anything)
             .times(MercuryItem::Importer::MAX_TRANSACTION_PAGES)
             .returns(*pages)

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_warning").count }, 1 do
      run_import
    end

    entry = DebugLogEntry.where(category: "provider_sync_warning").recent.first
    assert_equal [ "mercury", "warn", mercury_account.account_provider ], [ entry.provider_key, entry.level, entry.account_provider ]
    assert_equal(
      { "mercury_item_id" => @item.id, "account_id" => "acc_runaway", "pages" => MercuryItem::Importer::MAX_TRANSACTION_PAGES, "page_size" => 1 },
      entry.metadata
    )
  end

  test "an API that ignores the offset stops after two requests" do
    _account, mercury_account = create_linked_account("acc_no_offset")
    use_paging_provider("acc_no_offset")
    MercuryItem::Importer.any_instance.stubs(:transactions_page_size).returns(2)
    @provider.expects(:get_account_transactions).with("acc_no_offset", anything).twice
             .returns({ transactions: [ tx_payload("tx_1"), tx_payload("tx_2") ] })

    assert_no_difference -> { DebugLogEntry.where(category: "provider_sync_warning").count } do
      run_import
    end

    assert_equal %w[tx_1 tx_2], mercury_account.reload.raw_transactions_payload.map { |tx| tx["id"] }
  end

  # ---------------------------------------------------------------------------
  # sync window
  # ---------------------------------------------------------------------------

  test "uses 90-day window for account with no stored transactions" do
    create_linked_account("acc_first")
    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_first", "Checking") ] })

    captured_start = nil
    @provider.stubs(:get_account_transactions).with do |_id, opts|
      captured_start = opts[:start_date]
      true
    end.returns({ transactions: [] })

    run_import

    assert_not_nil captured_start
    assert captured_start >= 91.days.ago.to_date,
           "first-sync start date must be within 90 days"
  end

  test "uses last_synced_at minus 7 days when account has existing transactions" do
    ten_days_ago = 10.days.ago
    _account, mercury_account = create_linked_account("acc_resync",
      raw_transactions: [ tx_payload("existing_tx") ])

    @item.stubs(:last_synced_at).returns(ten_days_ago)
    @provider.stubs(:get_accounts).returns({ accounts: [ account_payload("acc_resync", "Checking") ] })

    captured_start = nil
    @provider.stubs(:get_account_transactions).with do |_id, opts|
      captured_start = opts[:start_date]
      true
    end.returns({ transactions: [] })

    run_import

    expected = (ten_days_ago - 7.days).to_date
    assert_equal expected, captured_start.to_date
  end

  # ---------------------------------------------------------------------------
  # auth error handling
  # ---------------------------------------------------------------------------

  test "marks item requires_update and raises on 401 from Mercury API" do
    @provider.stubs(:get_accounts).raises(
      Provider::Mercury::MercuryError.new("Unauthorized", :unauthorized)
    )

    assert_raises(Provider::Mercury::MercuryError) { run_import }

    assert @item.reload.requires_update?
  end

  private

    def run_import
      MercuryItem::Importer.new(@item, mercury_provider: @provider).import
    end

    def create_linked_account(account_id, raw_transactions: [])
      account = @family.accounts.create!(
        name: account_id, balance: 0, currency: "USD",
        accountable: Depository.new(subtype: "checking")
      )
      mercury_account = @item.mercury_accounts.create!(
        name: account_id, account_id: account_id, currency: "USD",
        current_balance: 0, raw_transactions_payload: raw_transactions
      )
      AccountProvider.create!(provider: mercury_account, account: account)
      [ account, mercury_account ]
    end

    # A provider without the setup's catch-all transactions stub, so a request
    # no test expects fails it.
    def use_paging_provider(account_id)
      @provider = mock("mercury_provider")
      @provider.stubs(:get_accounts).returns({ accounts: [ account_payload(account_id, "Checking") ] })
    end

    def expect_page(account_id, offset:, limit:, ids:)
      @provider.expects(:get_account_transactions)
               .with(account_id, has_entries(offset: offset, limit: limit))
               .returns({ transactions: ids.map { |id| tx_payload(id) } })
    end

    def account_payload(id, name, balance: 1_000.0)
      { id: id, name: name, nickname: nil, legalBusinessName: nil,
        currentBalance: balance, availableBalance: balance,
        status: "active", type: "checking", kind: "checking" }
    end

    def tx_payload(id, amount: 50.0, status: "sent")
      { "id" => id, "amount" => amount, "status" => status,
        "bankDescription" => "Test", "createdAt" => "2024-06-01T00:00:00Z",
        "postedAt" => "2024-06-01T00:00:00Z" }
    end
end
