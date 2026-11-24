require "test_helper"

# A bank that reports only an available (ITAV) balance has already deducted its
# pending card payments. Sure builds balance history from posted entries only, so
# the importer adds those pending payments back before the balance becomes the
# current anchor. Booked balances are already posted-only and stay as reported.
class EnableBankingItem::ImporterPendingBalanceTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Revolut",
      country_code: "LT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      status: :good
    )

    @enable_banking_account = @enable_banking_item.enable_banking_accounts.create!(
      name: "Main",
      uid: "identification_hash_pending",
      account_id: "22222222-2222-2222-2222-222222222222",
      currency: "EUR",
      account_status: "active",
      provider: "enable_banking"
    )

    @account = Account.create!(
      family: @family,
      name: "Revolut Main",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Depository.create!
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
    @enable_banking_account.reload

    @mock_provider = OpenStruct.new
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
    @importer.stubs(:include_pending?).returns(true)
  end

  test "an available balance gets this sync's pending card payments added back" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "the descriptive interimAvailable spelling is treated the same way" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "20.00"), pending_tx("card_2", "5.50") ])
    stub_balances(balance("interimAvailable", "74.50"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "the descriptive expected spelling is treated like XPCD" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "10.00"), pending_tx("incoming_1", "4.00", indicator: "CRDT") ])
    stub_balances(balance("expected", "94.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "a pending row without a currency is added back" do
    card = pending_tx("card_1", "36.01")
    card[:transaction_amount] = { amount: "36.01" }
    stub_transactions(booked: [], pending: [ card ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "a balance without a currency gets the pending rows added back" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    itav = balance("ITAV", "64.53")
    itav[:balance_amount] = { amount: "64.53" }
    stub_balances(itav)

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "a booked balance stays as reported when the bank also sends pending rows" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITBD", "100.54"), balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "a closing booked balance stays as reported" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("CLBD", "100.54"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "an available balance does not count pending incoming money" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "10.00"), pending_tx("refund_1", "4.00", indicator: "CRDT") ])
    stub_balances(balance("ITAV", "90.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "an expected balance has pending items in both directions reversed" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "10.00"), pending_tx("incoming_1", "4.00", indicator: "CRDT") ])
    stub_balances(balance("XPCD", "94.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "a pending row that settles in the same sync is not added back" do
    settled = pending_tx("card_1", "36.01").merge(status: "BOOK")
    stub_transactions(booked: [ settled ], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  test "a pending row in the booked response is not added back when its booked row came too" do
    salary = booked_tx("salary_1", "150.00", date: (Date.current - 5).to_s, indicator: "CRDT")
    pending_copy = pending_tx("card_1", "36.01", date: (Date.current - 1).to_s)
    booked_copy = booked_tx("card_1", "36.01", date: Date.current.to_s)
    stub_transactions(booked: [ salary, pending_copy, booked_copy ], pending: [])
    stub_balances(balance("ITAV", "113.99"))

    sync_balance

    assert_equal BigDecimal("113.99"), @enable_banking_account.reload.current_balance
  end

  test "a settled pending row in the booked response is matched by id or by entry reference" do
    salary = booked_tx("salary_1", "150.00", date: (Date.current - 5).to_s, indicator: "CRDT")
    # Gains a transaction_id when it books; the entry_reference stays.
    by_reference = pending_tx("card_r", "10.00", date: (Date.current - 1).to_s).merge(transaction_id: nil)
    by_reference_booked = booked_tx("card_r", "10.00", date: Date.current.to_s)
    # Keeps its transaction_id; the entry_reference changes.
    by_id = pending_tx("card_i", "5.00", date: (Date.current - 1).to_s)
    by_id_booked = booked_tx("card_i", "5.00", date: Date.current.to_s).merge(entry_reference: "ref_card_i_booked")
    stub_transactions(booked: [ salary, by_reference, by_reference_booked, by_id, by_id_booked ], pending: [])
    stub_balances(balance("ITAV", "135.00"))

    sync_balance

    assert_equal BigDecimal("135.00"), @enable_banking_account.reload.current_balance
  end

  test "pending rows in another currency are not added back" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01", currency: "USD") ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  # Through the freshness rule, an available balance dated after a period
  # boundary balance is picked over it, so it is adjusted like an ITAV-only one.
  test "an available balance picked over an older PRCD or OPBD balance gets pending added back" do
    %w[PRCD OPBD].each do |boundary|
      stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
      stub_balances(
        balance(boundary, "150.00", reference_date: (Date.current - 1).to_s),
        balance("ITAV", "64.53", reference_date: Date.current.to_s)
      )

      sync_balance

      assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance, boundary
      assert_equal BigDecimal("36.01"), @enable_banking_account.pending_total, boundary
    end
  end

  test "a PRCD balance an available balance does not replace stays as reported" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(
      balance("PRCD", "150.00", reference_date: Date.current.to_s),
      balance("ITAV", "64.53", reference_date: Date.current.to_s)
    )

    sync_balance

    assert_equal BigDecimal("150.00"), @enable_banking_account.reload.current_balance
    assert_equal BigDecimal("0"), @enable_banking_account.pending_total
  end

  test "a closing available balance stays as reported" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("CLAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  test "an unidentified card hold labelled CRDT is added back as the outflow its entry records" do
    stub_transactions(booked: [ unidentified_hold("20.00") ], pending: [])
    stub_balances(balance("ITAV", "80.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "an expected balance reverses an unidentified card hold labelled CRDT as an outflow" do
    stub_transactions(booked: [ unidentified_hold("20.00") ], pending: [])
    stub_balances(balance("XPCD", "80.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "the balance stays as reported when pending transactions are not synced" do
    @importer.stubs(:include_pending?).returns(false)
    # The bank returns pending rows in the booked response too; with pending
    # sync off they are dropped, so none of them is added back.
    in_booked = pending_tx("card_2", "10.00")
    stub_transactions(booked: [ in_booked, unidentified_hold("20.00") ], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
    assert_nil @enable_banking_account.pending_total
  end

  test "an available balance is not stored when the pending fetch fails after the booked one" do
    # The booked response already carries one pending row, but the full pending
    # set is unknown once the PDNG fetch fails.
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns([ [ pending_tx("card_2", "10.00") ], false ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG"))
      .raises(Provider::EnableBanking::EnableBankingError.new("boom", :request_failed))
    stub_balances(balance("ITAV", "64.53"))
    # A figure left from an earlier fetch must not be written as the anchor.
    @enable_banking_account.update_columns(current_balance: 50)

    @importer.send(:fetch_and_store_transactions, @enable_banking_account)
    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_nil @enable_banking_account.reload.current_balance
  end

  test "an available balance is not stored when the transactions cannot be saved" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITAV", "64.53"))
    @enable_banking_account.update_columns(current_balance: 50)
    @enable_banking_account.stubs(:upsert_enable_banking_transactions_snapshot!).raises(ActiveRecord::StatementInvalid, "boom")

    assert_not @importer.send(:fetch_and_store_transactions, @enable_banking_account)[:success]
    assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)

    assert_nil @enable_banking_account.reload.current_balance
  end

  test "a booked balance is still stored when the transaction fetch fails" do
    @importer.stubs(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("slow down", :rate_limited))
    stub_balances(balance("CLBD", "100.54"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
  end

  test "with pending sync off an available balance is still stored when the transaction fetch fails" do
    @importer.stubs(:include_pending?).returns(false)
    @importer.stubs(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("slow down", :rate_limited))
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  test "a liability balance is still stored when the transaction fetch fails" do
    @account.update!(accountable: CreditCard.create!)
    @enable_banking_account.reload
    @importer.stubs(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("slow down", :rate_limited))
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  test "a pending row dated before the sync window is still added back" do
    @enable_banking_item.update!(sync_start_date: Date.current - 5)
    stub_transactions(booked: [], pending: [ pending_tx("card_old", "36.01", date: (Date.current - 30).to_s) ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
    assert_empty @enable_banking_account.raw_transactions_payload.to_a, "the row itself is outside the window"
  end

  test "a pending fetch cut short after its first page leaves the pending total unknown" do
    page_error = Provider::EnableBanking::EnableBankingError.new("bad continuation key", :bad_request)
    pages = 0
    @mock_provider.define_singleton_method(:get_account_transactions) do |transaction_status:, **|
      next { transactions: [] } if transaction_status == "BOOK"

      pages += 1
      raise page_error if pages > 1

      { transactions: [ { entry_reference: "ref_card_1", transaction_id: "txn_card_1", booking_date: Date.current.to_s,
                          transaction_amount: { amount: "10.00", currency: "EUR" }, credit_debit_indicator: "DBIT",
                          remittance_information: [ "Merchant card_1" ], status: "PDNG" } ],
        continuation_key: "page_2" }
    end
    stub_balances(balance("ITAV", "70.00"))

    sync_balance

    assert_equal BigDecimal("80.00"), @enable_banking_account.reload.current_balance
    assert_nil @enable_banking_account.pending_total, "the second page's pending rows are unknown"
  end

  test "a pending fetch stopped on a repeated continuation key leaves the pending total unknown" do
    @mock_provider.define_singleton_method(:get_account_transactions) do |transaction_status:, **|
      next { transactions: [] } if transaction_status == "BOOK"

      { transactions: [], continuation_key: "same_key" }
    end
    stub_balances(balance("ITAV", "70.00"))

    sync_balance

    assert_nil @enable_banking_account.reload.pending_total
  end

  test "a balance without a currency only counts pending rows in the account's currency" do
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "10.00"), pending_tx("card_usd", "20.00", currency: "USD") ])
    itav = balance("ITAV", "90.00")
    itav[:balance_amount] = { amount: "90.00" }
    stub_balances(itav)

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
    assert_equal BigDecimal("10.00"), @enable_banking_account.pending_total
  end

  test "a pending row with its currency at the top level is matched on it" do
    usd = pending_tx("card_usd", "20.00").except(:transaction_amount).merge(amount: "20.00", currency: "USD")
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "10.00"), usd ])
    stub_balances(balance("ITAV", "90.00"))

    sync_balance

    assert_equal BigDecimal("100.00"), @enable_banking_account.reload.current_balance
  end

  test "a rejected pending request leaves an available balance's pending total unknown" do
    # The booked response still carries one pending row, which is added back.
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns([ [ pending_tx("card_2", "10.00") ], false ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG"))
      .raises(Provider::EnableBanking::EnableBankingError.new("unsupported", :validation_error))
    stub_balances(balance("ITAV", "54.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
    assert_nil @enable_banking_account.pending_total, "other pending rows may be missing, so the anchor must not become a waypoint"
  end

  test "a booked fetch cut short leaves an available balance's pending total unknown" do
    page_error = Provider::EnableBanking::EnableBankingError.new("bad continuation key", :validation_error)
    pages = 0
    @mock_provider.define_singleton_method(:get_account_transactions) do |transaction_status:, **|
      next { transactions: [] } if transaction_status == "PDNG"

      pages += 1
      raise page_error if pages > 1

      { transactions: [], continuation_key: "page_2" }
    end
    stub_balances(balance("ITAV", "70.00"))

    sync_balance

    assert_equal BigDecimal("70.00"), @enable_banking_account.reload.current_balance
    assert_nil @enable_banking_account.pending_total
  end

  # With the PDNG request rejected and the pending payment absent from the
  # booked response, nothing tells the importer the balance includes it. The
  # balance is stored as the bank reports it, so history is low by the payment
  # while it is pending, as on main. Its unknown pending total keeps the anchor
  # from becoming a waypoint, so history is right once the payment books.
  test "with the pending request rejected history is off while a payment is pending and right once it books" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")
    rejected = Provider::EnableBanking::EnableBankingError.new("unsupported", :validation_error)
    sync = lambda do |booked|
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(true)
      @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns([ booked, false ])
      @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG")).raises(rejected)
      # ITAV already deducts the card payment of 36.01 pending at the 08-25 sync.
      stub_balances(balance("ITAV", "80.99"))
      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
      %w[2026-08-23 2026-08-24 2026-08-25].index_with { |date| @account.balances.find_by(date: Date.parse(date))&.end_balance&.to_s("F") }
    end

    travel_to Time.zone.local(2026, 8, 25, 9) do
      assert_equal({ "2026-08-23" => "113.99", "2026-08-24" => "80.99", "2026-08-25" => "80.99" }, sync.call([ salary, lunch ]))
      assert_nil @enable_banking_account.reload.pending_total
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      # Booked the next day, so a waypoint left at 80.99 on 08-25 would show.
      card = booked_tx("card_1", "36.01", date: "2026-08-26")
      assert_equal({ "2026-08-23" => "150.0", "2026-08-24" => "117.0", "2026-08-25" => "117.0" }, sync.call([ salary, lunch, card ]))
    end
    assert_empty @account.valuations.reconciliation
  end

  test "an available balance with a rejected pending request is not vouched for as the next anchor" do
    stub_transactions(booked: [], pending: [])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG"))
      .raises(Provider::EnableBanking::EnableBankingError.new("unsupported", :validation_error))
    stub_balances(balance("ITAV", "64.53"))

    sync_balance
    EnableBankingAccount::Processor.new(@enable_banking_account.reload).process

    assert_not @enable_banking_account.reload.balance_evidence_verified?
    assert_not @enable_banking_account.balance_verified?, "the next sync's tiebreak must not start from this anchor"
  end

  test "a rejected pending request leaves a booked balance's pending total at zero" do
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns([ [], false ])
    @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG"))
      .raises(Provider::EnableBanking::EnableBankingError.new("unsupported", :bad_request))
    stub_balances(balance("CLBD", "100.54"))

    sync_balance

    assert_equal BigDecimal("100.54"), @enable_banking_account.reload.current_balance
    assert_equal BigDecimal("0"), @enable_banking_account.pending_total
  end

  test "the same-type tiebreak compares the anchor with the bank's figures plus pending" do
    create_anchor(100, Date.current - 2)
    @enable_banking_account.update!(balance_verified: true, anchor_pending_total: 0)
    yesterday = booked_tx("coffee_1", "10.00", date: (Date.current - 1).to_s)
    stub_transactions(booked: [ yesterday ], pending: [ pending_tx("card_1", "20.00") ])
    # Posted: 100 - 10 = 90. The bank deducts the 20 pending, so 70 is right.
    stub_balances(balance("ITAV", "90.00"), balance("ITAV", "70.00"))

    sync_balance

    assert_equal BigDecimal("90.00"), @enable_banking_account.reload.current_balance
    assert_equal BigDecimal("20.00"), @enable_banking_account.pending_total
    assert @enable_banking_account.balance_evidence_verified?
    assert_equal "anchor", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  # A payment pending at the anchor that books dated before the anchor's day
  # falls outside the bookings the check counts, yet the anchor had it added
  # back. The expected balance is then off by it and could match the wrong figure.
  test "the same-type tiebreak does not use an anchor that had pending rows" do
    create_anchor(117, Date.current - 1)
    @enable_banking_account.update!(balance_verified: true, anchor_pending_total: BigDecimal("36.01"))
    card = booked_tx("card_1", "36.01", date: (Date.current - 2).to_s)
    stub_transactions(booked: [ card ], pending: [])
    # Posted: 117 - 36.01 = 80.99. Counting only bookings from the anchor's day
    # on would expect 117.
    stub_balances(balance("ITAV", "117.00"), balance("ITAV", "80.99"))

    sync_balance

    assert_equal BigDecimal("80.99"), @enable_banking_account.reload.current_balance
    assert_not @enable_banking_account.balance_evidence_verified?
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  # An anchor with no recorded total may be the bank's own figure (written
  # before the upgrade, or with pending sync off), which already deducts the
  # pending payment. Subtracting this sync's adjustment from it counts it twice.
  test "the same-type tiebreak does not adjust an anchor with an unknown pending total" do
    create_anchor(80, Date.current - 1)
    @enable_banking_account.update!(balance_verified: true, anchor_pending_total: nil)
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "20.00") ])
    stub_balances(balance("ITAV", "80.00"), balance("ITAV", "60.00"))

    sync_balance

    assert_not @enable_banking_account.reload.balance_evidence_verified?
    assert_equal "lowest", DebugLogEntry.order(:created_at).last.metadata["stage"]
  end

  test "a liability account keeps the bank's figure" do
    @account.update!(accountable: CreditCard.create!)
    @enable_banking_account.reload
    stub_transactions(booked: [], pending: [ pending_tx("card_1", "36.01") ])
    stub_balances(balance("ITAV", "64.53"))

    sync_balance

    assert_equal BigDecimal("64.53"), @enable_banking_account.reload.current_balance
  end

  test "history before a pending payment does not move when the balance includes it" do
    travel_to Date.new(2026, 8, 25) do
      @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
      opening = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
      lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")
      stub_transactions(booked: [ opening, lunch ], pending: [ pending_tx("card_1", "36.01", date: "2026-08-25") ])
      # 150.00 - 33.00 posted, minus 36.01 still pending.
      stub_balances(balance("ITAV", "80.99"))

      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
      Balance::Materializer.new(@account.reload, strategy: :reverse).materialize_balances

      assert_equal BigDecimal("117.00"), @account.balances.find_by(date: Date.new(2026, 8, 24)).end_balance
      assert_equal BigDecimal("150.00"), @account.balances.find_by(date: Date.new(2026, 8, 23)).end_balance
    end
  end

  test "history stays right when a pending payment books dated on the day it was pending" do
    assert_history_across_settlement(booked_on: Date.new(2026, 8, 25), expected: {
      Date.new(2026, 8, 23) => "150.00",
      Date.new(2026, 8, 24) => "117.00",
      Date.new(2026, 8, 25) => "80.99",
      Date.new(2026, 8, 26) => "80.99"
    })
  end

  # Account::CurrentBalanceManager's ledger check keeps the pending entry out:
  # its booked row updates it in place, so it keeps the created_at it had before
  # the anchor was written, on the anchor's day.
  test "with the explained-anchor check on history stays right when a pending payment books dated on the day it was pending" do
    Rails.configuration.x.balance.stubs(:reuse_explained_anchor).returns(true)

    assert_history_across_settlement(booked_on: Date.new(2026, 8, 25), expected: {
      Date.new(2026, 8, 23) => "150.00",
      Date.new(2026, 8, 24) => "117.00",
      Date.new(2026, 8, 25) => "80.99",
      Date.new(2026, 8, 26) => "80.99"
    })
  end

  test "history stays right when a pending payment books dated the next day" do
    assert_history_across_settlement(booked_on: Date.new(2026, 8, 26), expected: {
      Date.new(2026, 8, 23) => "150.00",
      Date.new(2026, 8, 24) => "117.00",
      Date.new(2026, 8, 25) => "117.00",
      Date.new(2026, 8, 26) => "80.99"
    })
  end

  test "a later sync whose transaction fetch fails keeps the posted-only anchor" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      sync_and_process(booked: [ salary, lunch ], pending: [ pending_tx("card_1", "36.01", date: "2026-08-25") ], itav: "80.99")
    end

    travel_to Time.zone.local(2026, 8, 25, 18) do
      # Transactions are rate limited, the balance still comes back.
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(true)
      @importer.stubs(:fetch_paginated_transactions).raises(Provider::EnableBanking::EnableBankingError.new("slow down", :rate_limited))
      stub_balances(balance("ITAV", "80.99"))
      @importer.send(:fetch_and_store_transactions, @enable_banking_account)
      assert_not @importer.send(:fetch_and_update_balance, @enable_banking_account)
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process

      assert_equal BigDecimal("117.00"), Account.find(@account.id).current_anchor_balance
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      card = booked_tx("card_1", "36.01", date: "2026-08-26")
      sync_and_process(booked: [ salary, lunch, card ], pending: [], itav: "80.99")
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    expected = {
      Date.new(2026, 8, 23) => BigDecimal("150.00"),
      Date.new(2026, 8, 24) => BigDecimal("117.00"),
      Date.new(2026, 8, 25) => BigDecimal("117.00"),
      Date.new(2026, 8, 26) => BigDecimal("80.99")
    }
    assert_equal expected, expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
    assert_empty @account.valuations.reconciliation
  end

  test "an anchor written before the adjustment was recorded is not kept as a waypoint" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      sync_and_process(booked: [ salary, lunch ], pending: [ pending_tx("card_1", "36.01", date: "2026-08-25") ], itav: "80.99")
      # As written before the upgrade: the bank's figure, nothing recorded.
      @account.valuations.current_anchor.first.entry.update!(amount: 80.99)
      @enable_banking_account.update_columns(pending_total: nil, anchor_pending_total: nil)
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      card = booked_tx("card_1", "36.01", date: "2026-08-26")
      sync_and_process(booked: [ salary, lunch, card ], pending: [], itav: "80.99")
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    expected = {
      Date.new(2026, 8, 23) => BigDecimal("150.00"),
      Date.new(2026, 8, 24) => BigDecimal("117.00"),
      Date.new(2026, 8, 25) => BigDecimal("117.00"),
      Date.new(2026, 8, 26) => BigDecimal("80.99")
    }
    assert_equal expected, expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
    assert_empty @account.valuations.reconciliation
  end

  test "an anchor from a booked balance records no adjustment and still becomes a waypoint" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")

    [ Time.zone.local(2026, 8, 25, 9), Time.zone.local(2026, 8, 26, 9) ].each do |time|
      travel_to time do
        @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
        @importer.stubs(:include_pending?).returns(true)
        stub_transactions(booked: [ salary ], pending: [])
        stub_balances(balance("CLBD", "150.00"))
        sync_balance
        EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
      end
    end

    assert_equal BigDecimal("0"), @enable_banking_account.reload.anchor_pending_total
    assert @account.valuations.reconciliation.joins(:entry).exists?(entries: { date: Date.new(2026, 8, 25) })
  end

  test "an anchor stored with pending sync off is not kept as a waypoint once it is turned on" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      sync_and_process(booked: [ salary, lunch ], pending: [ pending_tx("card_1", "36.01", date: "2026-08-25") ], itav: "80.99", include_pending: false)
      assert_nil @enable_banking_account.reload.anchor_pending_total
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      card = booked_tx("card_1", "36.01", date: "2026-08-26")
      sync_and_process(booked: [ salary, lunch, card ], pending: [], itav: "80.99")
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    expected = {
      Date.new(2026, 8, 23) => BigDecimal("150.00"),
      Date.new(2026, 8, 24) => BigDecimal("117.00"),
      Date.new(2026, 8, 25) => BigDecimal("117.00"),
      Date.new(2026, 8, 26) => BigDecimal("80.99")
    }
    assert_equal expected, expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
    assert_empty @account.valuations.reconciliation
  end

  test "an expected balance whose pending items cancel out is not kept as a waypoint" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")
    refund = pending_tx("refund_1", "10.00", indicator: "CRDT", date: "2026-08-25")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(true)
      stub_transactions(booked: [ salary, lunch ], pending: [ pending_tx("card_1", "10.00", date: "2026-08-25"), refund ])
      stub_balances(balance("XPCD", "117.00"))
      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
      assert_equal BigDecimal("20.00"), @enable_banking_account.reload.anchor_pending_total
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(true)
      card = booked_tx("card_1", "10.00", date: "2026-08-25")
      stub_transactions(booked: [ salary, lunch, card ], pending: [ refund ])
      stub_balances(balance("XPCD", "117.00"))
      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    expected = {
      Date.new(2026, 8, 23) => BigDecimal("150.00"),
      Date.new(2026, 8, 24) => BigDecimal("117.00"),
      Date.new(2026, 8, 25) => BigDecimal("107.00"),
      Date.new(2026, 8, 26) => BigDecimal("107.00")
    }
    assert_equal expected, expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
    assert_empty @account.valuations.reconciliation
  end

  test "an available-balance anchor with only pending incoming money is not kept as a waypoint" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
    lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      # ITAV leaves the pending refund out, so nothing is added back.
      sync_and_process(booked: [ salary, lunch ], pending: [ pending_tx("refund_1", "20.00", indicator: "CRDT", date: "2026-08-25") ], itav: "117.00")
      assert_equal BigDecimal("117.00"), Account.find(@account.id).current_anchor_balance
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      refund = booked_tx("refund_1", "20.00", date: "2026-08-25", indicator: "CRDT")
      sync_and_process(booked: [ salary, lunch, refund ], pending: [], itav: "137.00")
      Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
    end

    expected = {
      Date.new(2026, 8, 23) => BigDecimal("150.00"),
      Date.new(2026, 8, 24) => BigDecimal("117.00"),
      Date.new(2026, 8, 25) => BigDecimal("137.00"),
      Date.new(2026, 8, 26) => BigDecimal("137.00")
    }
    assert_equal expected, expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
    assert_empty @account.valuations.reconciliation
  end

  test "a booked-balance anchor still becomes a waypoint when the next balance is adjusted" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(true)
      stub_transactions(booked: [ salary ], pending: [])
      stub_balances(balance("CLBD", "150.00"))
      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      sync_and_process(booked: [ salary ], pending: [ pending_tx("card_1", "10.00", date: "2026-08-26") ], itav: "140.00")
    end

    waypoint = @account.valuations.reconciliation.joins(:entry).find_by(entries: { date: Date.new(2026, 8, 25) })
    assert waypoint, "a booked balance is a posted-only figure, so it stays a waypoint"
    assert_equal BigDecimal("150.00"), waypoint.entry.amount
  end

  test "a liability anchor records no adjustment and still becomes a waypoint" do
    @account.update!(accountable: CreditCard.create!)
    @enable_banking_account.reload

    [ Time.zone.local(2026, 8, 25, 9), Time.zone.local(2026, 8, 26, 9) ].each do |time|
      travel_to time do
        sync_and_process(booked: [], pending: [ pending_tx("card_1", "10.00") ], itav: "64.53")
      end
    end

    assert_equal BigDecimal("0"), @enable_banking_account.reload.anchor_pending_total
    assert @account.valuations.reconciliation.joins(:entry).exists?(entries: { date: Date.new(2026, 8, 25) })
  end

  test "an anchor without pending added back still becomes a waypoint the next day" do
    @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
    salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")

    travel_to Time.zone.local(2026, 8, 25, 9) do
      sync_and_process(booked: [ salary ], pending: [], itav: "150.00")
    end

    travel_to Time.zone.local(2026, 8, 26, 9) do
      sync_and_process(booked: [ salary ], pending: [], itav: "150.00")
    end

    waypoint = @account.valuations.reconciliation.joins(:entry).find_by(entries: { date: Date.new(2026, 8, 25) })
    assert waypoint, "a booked-only anchor keeps its waypoint"
    assert_equal BigDecimal("150.00"), waypoint.entry.amount
  end

  private

    # Salary 150 on 08-20 and lunch 33 on 08-24. A card payment of 36.01 is
    # pending at the 08-25 sync (ITAV 80.99 already deducts it) and booked by the
    # 08-26 sync, dated booked_on.
    def assert_history_across_settlement(booked_on:, expected:)
      @enable_banking_item.update!(sync_start_date: Date.new(2026, 8, 1))
      salary = booked_tx("salary_1", "150.00", date: "2026-08-20", indicator: "CRDT")
      lunch = booked_tx("lunch_1", "33.00", date: "2026-08-24")

      travel_to Time.zone.local(2026, 8, 25, 9) do
        sync_and_process(booked: [ salary, lunch ], pending: [ pending_tx("card_1", "36.01", date: "2026-08-25") ], itav: "80.99")
        assert_equal BigDecimal("117.00"), Account.find(@account.id).current_anchor_balance
      end

      travel_to Time.zone.local(2026, 8, 26, 9) do
        card = booked_tx("card_1", "36.01", date: booked_on.to_s)
        sync_and_process(booked: [ salary, lunch, card ], pending: [], itav: "80.99")
        # A fresh record: Account memoizes its current anchor.
        Balance::Materializer.new(Account.find(@account.id), strategy: :reverse).materialize_balances
      end

      actual = expected.keys.index_with { |date| @account.balances.find_by(date: date)&.end_balance }
      assert_equal expected.transform_values { |amount| BigDecimal(amount) }, actual
      assert_empty @account.valuations.reconciliation, "a pending-adjusted anchor must not become a waypoint"
    end

    # One sync: a fresh importer, as each sync builds its own.
    def sync_and_process(booked:, pending:, itav:, include_pending: true)
      @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
      @importer.stubs(:include_pending?).returns(include_pending)
      stub_transactions(booked: booked, pending: pending)
      stub_balances(balance("ITAV", itav))
      sync_balance
      EnableBankingAccount::Processor.new(@enable_banking_account.reload).process
    end

    def create_anchor(amount, date)
      @account.entries.create!(
        date: date,
        name: "Current balance",
        amount: amount,
        currency: "EUR",
        entryable: Valuation.new(kind: "current_anchor")
      )
    end

    # An authorisation hold without identifiers or counterparty, which some
    # ASPSPs label CRDT. Sure records it as a pending outflow.
    def unidentified_hold(amount)
      {
        entry_reference: nil,
        transaction_id: nil,
        booking_date: Date.current.to_s,
        transaction_amount: { amount: amount, currency: "EUR" },
        credit_debit_indicator: "CRDT",
        remittance_information: [ "474836xxxxxx6879 003015315475" ],
        status: "BOOK"
      }
    end

    def sync_balance
      @importer.send(:fetch_and_store_transactions, @enable_banking_account)
      assert @importer.send(:fetch_and_update_balance, @enable_banking_account)
    end

    def stub_transactions(booked:, pending:)
      @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "BOOK")).returns([ booked, false ])
      @importer.stubs(:fetch_paginated_transactions).with(@enable_banking_account, has_entries(transaction_status: "PDNG")).returns([ pending, false ])
    end

    def stub_balances(*balances)
      @mock_provider.stubs(:get_account_balances).returns(balances: balances)
    end

    def balance(type, amount, indicator: "CRDT", reference_date: nil)
      {
        balance_type: type,
        balance_amount: { amount: amount, currency: "EUR" },
        credit_debit_indicator: indicator,
        reference_date: reference_date
      }.compact
    end

    def pending_tx(id, amount, indicator: "DBIT", currency: "EUR", date: Date.current.to_s)
      {
        entry_reference: "ref_#{id}",
        transaction_id: "txn_#{id}",
        booking_date: date,
        transaction_amount: { amount: amount, currency: currency },
        credit_debit_indicator: indicator,
        remittance_information: [ "Merchant #{id}" ],
        status: "PDNG"
      }
    end

    def booked_tx(id, amount, date:, indicator: "DBIT")
      pending_tx(id, amount, indicator: indicator, date: date).merge(status: "BOOK")
    end
end
