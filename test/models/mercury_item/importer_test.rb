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

  test "first sync starts from the chosen start date when it is older than 90 days" do
    create_linked_account("acc_chosen")
    chosen = Date.current - 2.years
    @item.update!(sync_start_date: chosen)

    assert_equal chosen, first_requested_start_date("acc_chosen").to_date
  end

  test "first sync starts from the chosen start date when it is newer than 90 days" do
    create_linked_account("acc_recent")
    chosen = Date.current - 20.days
    @item.update!(sync_start_date: chosen)

    assert_equal chosen, first_requested_start_date("acc_recent").to_date
  end

  test "first sync reads the chosen start date as a day on the family calendar" do
    @family.update!(timezone: "Pacific/Auckland")
    create_linked_account("acc_zone")
    @item.update!(sync_start_date: Time.utc(2024, 3, 9, 23, 0, 0))

    assert_equal Date.new(2024, 3, 10), first_requested_start_date("acc_zone").to_date
  end

  test "first sync never starts after today when the chosen start date is in the future" do
    create_linked_account("acc_future")
    @item.update!(sync_start_date: 10.days.from_now)

    assert_equal @family.local_date, first_requested_start_date("acc_future").to_date
  end

  test "resync does not go back before the chosen start date" do
    chosen = Date.current - 3.days
    _account, _mercury_account = create_linked_account("acc_floor",
      raw_transactions: [ tx_payload("existing_tx") ])
    @item.update!(sync_start_date: chosen)
    @item.stubs(:last_synced_at).returns(1.day.ago)

    assert_equal chosen, first_requested_start_date("acc_floor").to_date
  end

  test "resync keeps the last sync buffer when it is after the chosen start date" do
    last_synced = 10.days.ago
    _account, _mercury_account = create_linked_account("acc_buffer",
      raw_transactions: [ tx_payload("existing_tx") ])
    @item.update!(sync_start_date: Date.current - 2.years)
    @item.stubs(:last_synced_at).returns(last_synced)

    assert_equal (last_synced - 7.days).to_date, first_requested_start_date("acc_buffer").to_date
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

    def first_requested_start_date(account_id)
      @provider.stubs(:get_accounts).returns({ accounts: [ account_payload(account_id, "Checking") ] })

      captured_start = nil
      @provider.stubs(:get_account_transactions).with do |_id, opts|
        captured_start = opts[:start_date]
        true
      end.returns({ transactions: [] })

      run_import
      captured_start
    end
end
