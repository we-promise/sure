require "test_helper"

# The chunked backfill walks back in 60-day windows and stops after two
# consecutive windows with no history. Whether a window "had history" must come
# from what SimpleFIN returned for it, not from how much the stored payloads grew:
# on a new connection nothing is linked yet during the claim-time sync, and the
# setup-time sync re-fetches transactions the claim-time sync already stored.
class SimplefinItem::ImporterChunkedHistoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SimpleFIN Chunked History Test",
      access_url: "https://example.com/access"
    )
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: nil)
    @importer.stubs(:perform_account_discovery)
    @item.stubs(:upsert_simplefin_snapshot!)
  end

  test "keeps walking back while windows return history when no account is linked yet" do
    # Three windows of history, then nothing older.
    stub_windows(
      [ tx("t1", 10.days.ago) ],
      [ tx("t2", 70.days.ago) ],
      [ tx("t3", 130.days.ago) ],
      [],
      []
    )

    @importer.send(:import_with_chunked_history)

    history = @importer.send(:stats)["chunked_history"]
    assert_equal 5, history["chunks_processed"]
    assert_equal "no_new_data", history["reason"]
    assert_equal %w[t1 t2 t3], stored_transaction_ids
  end

  test "keeps walking back when the first windows re-fetch transactions already stored" do
    # The claim-time sync already stored the two most recent windows.
    sfa = @item.simplefin_accounts.create!(
      name: "Checking", account_id: "sf_checking", account_type: "checking",
      currency: "USD", current_balance: 100,
      raw_transactions_payload: [ tx("t1", 10.days.ago), tx("t2", 70.days.ago) ]
    )
    accounts(:depository).update!(simplefin_account_id: sfa.id)

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

  test "counts history from every account in a window, not just the first" do
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

  private
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
