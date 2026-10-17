require "test_helper"

class WiseAccountTest < ActiveSupport::TestCase
  setup do
    @wise_item = wise_items(:one)
    @checking = wise_accounts(:checking)
    @jar = wise_accounts(:jar)
  end

  # jar?

  test "jar? returns false for STANDARD balance" do
    @checking.update!(raw_payload: { "type" => "STANDARD" })
    assert_not @checking.jar?
  end

  test "jar? returns true for SAVINGS balance" do
    @jar.update!(raw_payload: { "type" => "SAVINGS" })
    assert @jar.jar?
  end

  test "jar? returns false when raw_payload is nil" do
    @checking.update!(raw_payload: nil)
    assert_not @checking.jar?
  end

  # account_subtype

  test "account_subtype returns checking for STANDARD account" do
    @checking.update!(raw_payload: { "type" => "STANDARD" })
    assert_equal "checking", @checking.account_subtype
  end

  test "account_subtype returns savings for JAR account" do
    @jar.update!(raw_payload: { "type" => "SAVINGS" })
    assert_equal "savings", @jar.account_subtype
  end

  # upsert_wise_snapshot!

  # Card holds sit in reservedAmount and Sure books a card payment only once
  # Wise completes it, so the live balance counts the holds back in.
  test "upsert_wise_snapshot! updates balance from STANDARD response" do
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 2500.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 100.0, "currency" => "EUR" },
      "type" => "STANDARD"
    }

    @checking.upsert_wise_snapshot!(balance_data)

    assert_equal BigDecimal("2600.0"), @checking.current_balance
    assert_equal BigDecimal("100.0"), @checking.reserved_balance
    assert_equal "EUR", @checking.currency
    assert_equal "STANDARD", @checking.raw_payload["type"]
  end

  test "upsert_wise_snapshot! uses totalWorth for SAVINGS balance" do
    balance_data = {
      "id" => "10000002",
      "amount" => { "value" => 4000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 5000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }

    @jar.update!(name: nil)
    @jar.upsert_wise_snapshot!(balance_data)

    assert_equal BigDecimal("5000.0"), @jar.current_balance
    assert_equal "Jar", @jar.name
  end

  test "upsert_wise_snapshot! stores borderless_account_id in raw_payload" do
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" }
    }

    @checking.upsert_wise_snapshot!(balance_data, borderless_account_id: 88888001, recipient_id: 99999001)

    assert_equal 88888001, @checking.raw_payload["borderless_account_id"]
    assert_equal 99999001, @checking.raw_payload["recipient_id"]
  end

  # A failed borderless/multi-currency-account lookup must not drop the ids
  # that decide transfer direction, nor Sure's own markers on the payload. A
  # pending clean-up cap bypass and the opening anchor Sure last set are among
  # those markers.
  test "upsert_wise_snapshot! keeps stored ids and markers the new payload lacks" do
    written = { "entry_id" => "f3a6c1d2-0000-4000-8000-000000000001", "date" => "2026-04-30", "amount" => "0.0" }
    @checking.update!(raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "borderless_account_id" => 88888001,
                                     "recipientId" => 77777001, "absent_count" => 1, "amount" => { "value" => 1.0 },
                                     "prune_cap_bypass" => [ "wise_transfer_1" ], "opening_anchor" => written })
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 2.0, "currency" => "EUR" },
      "recipientId" => 77777002
    }

    @checking.upsert_wise_snapshot!(balance_data)

    payload = @checking.reload.raw_payload
    assert_equal [ 99999001, 88888001, 77777002, 1 ], payload.values_at("recipient_id", "borderless_account_id", "recipientId", "absent_count")
    assert_equal 2.0, payload.dig("amount", "value")
    assert_equal [ "wise_transfer_1" ], @checking.prune_cap_bypass_ids
    assert_equal({ entry_id: written["entry_id"], date: Date.new(2026, 4, 30), amount: BigDecimal("0") }, @checking.written_opening_anchor)
  end

  test "upsert_wise_snapshot! preserves existing name" do
    @checking.update!(name: "My Wise EUR")
    balance_data = {
      "id" => "10000001",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "name" => "Jar"
    }

    @checking.upsert_wise_snapshot!(balance_data)

    assert_equal "My Wise EUR", @checking.name
  end

  # Processing a balance and deleting its stale entries hold a session-level
  # advisory lock, not a transaction.
  test "with_processing_lock holds the balance's advisory lock until the outermost block ends" do
    held_inside = nil
    held_after_inner = nil

    @checking.with_processing_lock do
      @checking.with_processing_lock { held_inside = processing_lock_held?(@checking) }
      held_after_inner = processing_lock_held?(@checking)
      assert_not processing_lock_held?(@jar)
    end

    assert held_inside
    assert held_after_inner
    assert_not processing_lock_held?(@checking)
  end

  test "with_processing_lock releases the lock when the block raises" do
    assert_raises(RuntimeError) { @checking.with_processing_lock { raise "boom" } }

    assert_not processing_lock_held?(@checking)
  end

  # Inside a caller's transaction (the linked-balance job used to wrap
  # processing in with_lock) a row's database error aborted it, the unlock
  # then failed and the lock stayed with the pooled connection, so every later
  # processing of the balance waited for it for good.
  test "with_processing_lock refuses to run inside a caller's transaction" do
    ran = false

    WiseAccount.transaction do
      assert_raises(WiseAccount::ProcessingInTransaction) { @checking.with_processing_lock { ran = true } }
    end

    assert_not ran
    assert_not processing_lock_held?(@checking)
  end

  # A broken connection Rails opened again runs the rest of the block on a
  # new session, which holds no lock: the block can tell, and the lock that
  # ended with the old session is not released twice.
  test "with_processing_lock tells when the session that took the lock ended" do
    sessions = [ 101, 101, 202, 202 ]
    @checking.stubs(:backend_pid).returns(*sessions)
    connection = WiseAccount.lease_connection
    connection.expects(:execute).with(regexp_matches(/pg_advisory_lock/)).once
    connection.expects(:execute).with(regexp_matches(/pg_advisory_unlock/)).never

    lost = []
    @checking.with_processing_lock { lost << @checking.processing_lock_lost? << @checking.processing_lock_lost? }

    assert_equal [ false, true ], lost
    assert_not @checking.processing_lock_lost?, "outside the lock"
  end

  test "with_processing_lock throws its connection away when the lock cannot be released" do
    connection = WiseAccount.lease_connection
    connection.expects(:throw_away!).once

    assert_raises(ActiveRecord::ConnectionFailed) do
      @checking.with_processing_lock do
        connection.stubs(:execute).raises(ActiveRecord::ConnectionFailed, "server closed the connection unexpectedly")
      end
    end
  ensure
    connection.unstub(:execute)
    connection.execute("SELECT pg_advisory_unlock_all()")
  end

  # The link request and a sync each write the snapshot from a copy they
  # loaded earlier; the opening anchor's mark is merged into the one stored
  # now, so neither loses the other's.
  test "remember_opening_anchor! keeps what another copy wrote meanwhile" do
    earlier_copy = WiseAccount.find(@checking.id)
    @checking.update!(raw_payload: { "type" => "STANDARD", "closed_at" => "2026-10-01T08:00:00Z" })
    anchor = Struct.new(:id, :date, :amount).new("anchor-1", Date.new(2024, 7, 9), 0)

    earlier_copy.remember_opening_anchor!(anchor)

    payload = @checking.reload.raw_payload
    assert_equal "2026-10-01T08:00:00Z", payload["closed_at"]
    assert_equal({ "entry_id" => "anchor-1", "date" => "2024-07-09", "amount" => "0.0" }, payload["opening_anchor"])
  end

  # A sync's statement coverage and clean-up marks are merged into the
  # snapshot as stored now, so an opening anchor recorded meanwhile stays.
  test "upsert_wise_transactions_snapshot! merges its marks into what another copy stored meanwhile" do
    earlier_copy = WiseAccount.find(@checking.id)
    @checking.update!(raw_payload: { "type" => "STANDARD", "opening_anchor" => { "entry_id" => "anchor-1" } })

    earlier_copy.upsert_wise_transactions_snapshot!([ { "id" => 1 } ], prune_cap_bypass: [ "wise_transfer_1" ])

    @checking.reload
    assert_equal [ { "id" => 1 } ], @checking.raw_transactions_payload
    assert_equal [ "anchor-1", [ "wise_transfer_1" ] ], @checking.raw_payload.values_at("opening_anchor", "prune_cap_bypass").then { |a, b| [ a["entry_id"], b ] }

    spending_copy = WiseAccount.find(@checking.id)
    @checking.update!(raw_payload: @checking.raw_payload.merge("closed_at" => "2026-10-01T08:00:00Z"))
    spending_copy.spend_prune_cap_bypass!
    payload = @checking.reload.raw_payload
    assert_equal "2026-10-01T08:00:00Z", payload["closed_at"]
    assert_not payload.key?("prune_cap_bypass")
  end

  test "closed_at and creation_time read Sure's and Wise's timestamps" do
    @checking.update!(raw_payload: { "type" => "STANDARD", "creationTime" => "2024-07-10T14:00:00.123Z" })
    assert_nil @checking.closed_at
    assert_equal Time.utc(2024, 7, 10, 14, 0, 0.123r), @checking.creation_time

    @checking.update!(raw_payload: { "closed_at" => "2026-10-01T08:00:00Z", "creationTime" => "not a time" })
    assert_equal Time.utc(2026, 10, 1, 8), @checking.closed_at
    assert_nil @checking.creation_time
  end

  test "upsert_wise_snapshot! defaults name to Wise JAR currency for new SAVINGS account" do
    @jar.update!(name: nil)
    balance_data = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS"
    }

    @jar.upsert_wise_snapshot!(balance_data)

    assert_equal "Wise JAR EUR", @jar.name
  end

  private

    # Whether this connection holds the balance's processing lock: an
    # advisory lock on two keys shows the first as classid and the second,
    # as an unsigned number, as objid.
    def processing_lock_held?(wise_account)
      ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, WiseAccount::PROCESSING_LOCK_NAMESPACE, wise_account.id.to_s ])).positive?
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted AND objsubid = 2
          AND classid = ? AND objid::bigint = (hashtext(?)::bigint & 4294967295)
      SQL
    end
end
