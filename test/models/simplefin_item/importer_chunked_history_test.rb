require "test_helper"

# The chunked backfill walks back in 60-day windows and stops after two
# consecutive windows with no history. Whether a window "had history" must come
# from what SimpleFIN returned for the linked accounts in it, not from how much
# the stored payloads grew: windows that re-fetch rows already stored (for
# example by account discovery) would otherwise read as empty.
class SimplefinItem::ImporterChunkedHistoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Chunked History Test",
      access_url: "https://example.com/access"
    )
    @checking = link_account("sf_checking", "Checking", accounts(:depository))
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    @importer.stubs(:perform_account_discovery)
    @item.stubs(:upsert_simplefin_snapshot!)
  end

  test "import keeps walking back and reports the transactions it stored" do
    # The linked account starts empty, so the public entry point chooses the
    # chunked path; three windows of history, then nothing older.
    @item.stubs(:last_synced_at).returns(2.days.ago)
    stub_windows(
      [ tx("t1", 10.days.ago) ],
      [ tx("t2", 70.days.ago) ],
      [ tx("t3", 130.days.ago) ],
      [],
      []
    )

    @importer.import

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 5, history["chunks_processed"]
    assert_equal "no_new_data", history["reason"]
    assert_equal 3, history["total_new_transactions"]
    assert_equal %w[t1 t2 t3], stored_transaction_ids
  end

  test "an account linked through AccountProvider counts as linked" do
    # Linking to an existing account creates only an AccountProvider row, with
    # no legacy simplefin_account_id on the account.
    accounts(:depository).update!(simplefin_account_id: nil)
    AccountProvider.create!(account: accounts(:depository), provider: @checking)
    @item.stubs(:last_synced_at).returns(2.days.ago)
    stub_windows(
      [ tx("t1", 10.days.ago) ],
      [ tx("t2", 70.days.ago) ],
      [],
      []
    )

    @importer.import

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 4, history["chunks_processed"]
    assert_equal 2, history["total_new_transactions"]
  end

  test "keeps walking back when the first windows re-fetch transactions already stored" do
    # Discovery (or an earlier sync) already stored the two most recent windows.
    @checking.update!(raw_transactions_payload: [ tx("t1", 10.days.ago), tx("t2", 70.days.ago) ])

    stub_windows(
      [ tx("t1", 10.days.ago) ],
      [ tx("t2", 70.days.ago) ],
      [ tx("t3", 130.days.ago) ],
      [],
      []
    )

    @importer.send(:import_with_chunked_history)

    assert_equal 5, @importer.send(:stats)["chunked_history"]["chunks_processed"]
    assert_includes stored_transaction_ids, "t3"
  end

  test "stops after two consecutive windows that return no history" do
    stub_windows([ tx("t1", 10.days.ago) ], [], [], [ tx("t4", 190.days.ago) ])

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 3, history["chunks_processed"]
    assert history["stopped_early"]
    assert_equal %w[t1], stored_transaction_ids
  end

  test "counts history from every linked account in a window, not just the first" do
    link_account("sf_savings", "Savings", accounts(:investment))
    quiet = ->(txns) { { id: "sf_savings", name: "Savings", currency: "USD", balance: "5.00", "balance-date": Time.current.to_i, transactions: txns } }
    busy = ->(txns) { { id: "sf_checking", name: "Checking", currency: "USD", balance: "100.00", "balance-date": Time.current.to_i, transactions: txns } }
    @importer.stubs(:fetch_accounts_data).returns(
      { accounts: [ quiet.call([]), busy.call([ tx("t1", 10.days.ago) ]) ] },
      { accounts: [ quiet.call([]), busy.call([ tx("t2", 70.days.ago) ]) ] },
      { accounts: [ quiet.call([]), busy.call([ tx("t3", 130.days.ago) ]) ] },
      { accounts: [ quiet.call([]), busy.call([]) ] },
      { accounts: [ quiet.call([]), busy.call([]) ] }
    )

    @importer.send(:import_with_chunked_history)

    assert_equal %w[t1 t2 t3], stored_transaction_ids
  end

  test "history from an account that is not linked does not extend the walk" do
    # The linked account is quiet; an unlinked (skipped) account has history in every window.
    @item.simplefin_accounts.create!(name: "Unlinked", account_id: "sf_unlinked", account_type: "checking", currency: "USD", current_balance: 1)
    responses = 6.times.map do |i|
      { accounts: [
          { id: "sf_checking", name: "Checking", currency: "USD", balance: "100.00", "balance-date": Time.current.to_i, transactions: [] },
          { id: "sf_unlinked", name: "Unlinked", currency: "USD", balance: "1.00", "balance-date": Time.current.to_i, transactions: [ tx("u#{i}", (10 + 60 * i).days.ago) ] }
      ] }
    end
    @importer.stubs(:fetch_accounts_data).returns(*responses)

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 2, history["chunks_processed"]
    assert_equal "no_new_data", history["reason"]
  end

  test "settled rows dated outside the window do not count as history" do
    # A bridge that returns the same old row for every request must not keep the walk going.
    old = tx("old", 400.days.ago)
    stub_windows([ tx("t1", 10.days.ago), old ], [ old ], [ old ], [ old ], [ old ], [ old ])

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 3, history["chunks_processed"]
    assert_equal "no_new_data", history["reason"]
  end

  test "pending rows returned with every window do not keep the walk going" do
    pending = { id: "p1", posted: 0, amount: "-5.00", description: "Pending", pending: true }
    stub_windows(
      [ tx("t1", 10.days.ago), pending ],
      [ pending ],
      [ pending ],
      [ tx("t4", 190.days.ago), pending ]
    )

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 3, history["chunks_processed"]
    assert history["stopped_early"]
  end

  test "settled rows without a posted date count toward the window of their transaction date" do
    # Some bridges omit posted on settled transactions and only send transacted_at.
    unposted = ->(id, time) { { id: id, transacted_at: time.to_i, amount: "-10.00", description: "Purchase #{id}" } }
    stub_windows(
      [ unposted.call("t1", 10.days.ago) ],
      [ unposted.call("t2", 70.days.ago) ],
      [ unposted.call("t3", 130.days.ago) ],
      [],
      []
    )

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 5, history["chunks_processed"]
    assert_equal %w[t1 t2 t3], stored_transaction_ids
  end

  test "rows flagged pending do not count as history even with an in-window posted date" do
    flagged = ->(id, time) { tx(id, time).merge(pending: true) }
    stub_windows(
      [ tx("t1", 10.days.ago) ],
      [ flagged.call("p2", 70.days.ago) ],
      [ flagged.call("p3", 130.days.ago) ],
      [ tx("t4", 190.days.ago) ]
    )

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 3, history["chunks_processed"]
    assert history["stopped_early"]
  end

  private
    def link_account(account_id, name, account)
      sfa = @item.simplefin_accounts.create!(
        name: name, account_id: account_id, account_type: "checking",
        currency: "USD", current_balance: 100
      )
      account.update!(simplefin_account_id: sfa.id)
      sfa
    end

    def stub_windows(*windows)
      responses = windows.map do |transactions|
        {
          accounts: [
            { id: "sf_checking", name: "Checking", currency: "USD", balance: "100.00",
              "balance-date": Time.current.to_i, transactions: transactions }
          ]
        }
      end
      @importer.stubs(:fetch_accounts_data).returns(*responses)
    end

    def tx(id, time)
      { id: id, posted: time.to_i, amount: "-10.00", description: "Purchase #{id}" }
    end

    def stored_transaction_ids
      @item.simplefin_accounts.find_by!(account_id: "sf_checking")
        .raw_transactions_payload.map { |t| t.with_indifferent_access[:id] }.sort
    end
end
