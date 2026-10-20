require "test_helper"

# The SimpleFIN bridge sometimes re-issues the ids of transactions it already
# served (#3436). A stored row the bridge no longer returns, re-delivered in the
# same response under a new id with identical content, is the same transaction:
# its entry moves to the new id and the payload keeps one row for it.
class SimplefinItem::ImporterRotatedIdsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)

    @account = Account.create!(
      family: @family,
      name: "Checking",
      currency: "USD",
      balance: 0,
      accountable: Depository.create!(subtype: :checking)
    )
    @sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      account_id: "ACT-1",
      name: "Checking",
      currency: "USD",
      current_balance: 0,
      account_type: "checking"
    )
    AccountProvider.create!(account: @account, provider: @sfa)

    @posted = 5.days.ago.beginning_of_day.to_i
  end

  def row(id, amount: "-10.25", description: "Amazon", payee: "Amazon", posted: @posted, transacted_at: @posted, **rest)
    { id: id, posted: posted, amount: amount, description: description, payee: payee, memo: "", transacted_at: transacted_at }.merge(rest).compact
  end

  # Stores rows as an earlier sync would have, and builds their entries.
  def store(*rows)
    @sfa.update!(raw_transactions_payload: rows)
    process
  end

  def import(*rows, sfa: @sfa)
    @importer.send(:import_account, { id: sfa.account_id, name: sfa.name, currency: "USD", balance: "0", transactions: rows })
    sfa.reload
  end

  def process
    SimplefinAccount::Transactions::Processor.new(@sfa.reload).process
  end

  def payload_ids(sfa = @sfa)
    sfa.reload.raw_transactions_payload.map { |t| t.with_indifferent_access[:id] }
  end

  def external_ids
    @account.entries.where(source: "simplefin").pluck(:external_id).sort
  end

  def entry_for(id)
    @account.entries.find_by!(source: "simplefin", external_id: "simplefin_#{id}")
  end

  test "P1 rotated id re-keys the existing entry instead of adding one" do
    store(row("T1"))
    entry = entry_for("T1")
    category = @family.categories.create!(name: "Shopping #{SecureRandom.hex(3)}")
    entry.transaction.update!(category: category)

    assert_no_difference -> { Entry.count } do
      import(row("T2"))
      process
    end

    entry.reload
    assert_equal "simplefin_T2", entry.external_id
    assert_equal category.id, entry.transaction.category_id
    assert_equal [ "T2" ], payload_ids
  end

  test "P3 repeated identical charges keep their count across a rotation" do
    store(row("T1"), row("T2"), row("T3"))
    assert_equal 3, external_ids.size

    assert_no_difference -> { Entry.count } do
      import(row("U1"), row("U2"), row("U3"))
      process
    end

    assert_equal %w[simplefin_U1 simplefin_U2 simplefin_U3], external_ids
    assert_equal %w[U1 U2 U3], payload_ids.sort
  end

  test "P4 a duplicate from before the fix stays deleted" do
    # The state the defect left behind: both ids stored, both with entries.
    store(row("T1"), row("T2"))

    import(row("T2"))
    assert_equal [ "T2" ], payload_ids

    entry_for("T1").destroy!
    assert_no_difference -> { Entry.count } do
      process
    end
    assert_equal [ "simplefin_T2" ], external_ids
  end

  test "P5 re-keyed entry keeps its recorded pending claim and pending date" do
    store(row("T1"))
    entry = entry_for("T1")
    pending_date = entry.date - 3.days
    entry.update_column(:date, pending_date)
    entry.transaction.update_column(:extra, entry.transaction.extra.merge("auto_claimed_pending_ids" => [ "simplefin_P0" ]))

    assert_no_difference -> { Entry.count } do
      import(row("T2"))
      process
    end

    entry.reload
    assert_equal "simplefin_T2", entry.external_id
    assert_equal [ "simplefin_P0" ], entry.transaction.extra["auto_claimed_pending_ids"]
    assert_equal pending_date, entry.date
  end

  test "N1 identical twins served together stay two entries" do
    import(row("T1"), row("T2"))
    process

    assert_equal %w[simplefin_T1 simplefin_T2], external_ids
  end

  test "N2 a stored twin that is still served keeps its id" do
    store(row("T1"))
    entry = entry_for("T1")

    # The new twin comes first, so pairing by position alone would hand it T1's entry.
    import(row("T2"), row("T1"))
    process

    assert_equal "simplefin_T1", entry.reload.external_id
    assert_equal %w[simplefin_T1 simplefin_T2], external_ids
    assert_equal %w[T1 T2], payload_ids.sort
  end

  test "N2 a partial rotation pairs the old id only with the new one" do
    store(row("T1"), row("T2"))
    entry = entry_for("T1")

    # T2 kept its id and comes first; only T1 was re-issued, as U1.
    assert_no_difference -> { Entry.count } do
      import(row("T2"), row("U1"))
      process
    end

    assert_equal "simplefin_U1", entry.reload.external_id
    assert_equal %w[simplefin_T2 simplefin_U1], external_ids
  end

  test "N3 pending and posted rows never pair" do
    store(row("P1", pending: true))
    entry = entry_for("P1")

    # Same dates, amount and text: only the pending flag differs.
    import(row("T9"))

    assert_equal "simplefin_P1", entry.reload.external_id
    assert_equal %w[P1 T9], payload_ids.sort
  end

  test "N3 an inferred-pending row does not pair with its posted version" do
    store(row("P1", posted: 0))
    entry = entry_for("P1")

    import(row("T9"))

    assert_equal "simplefin_P1", entry.reload.external_id
    assert_equal %w[P1 T9], payload_ids.sort
  end

  # Rows that differ in any field of the content key are different transactions.
  def assert_no_pairing(**changes)
    store(row("T1"))
    entry = entry_for("T1")

    import(row("T9", **changes))

    assert_equal "simplefin_T1", entry.reload.external_id
    assert_equal %w[T1 T9], payload_ids.sort
  end

  test "N3 rows with a different payee never pair" do
    assert_no_pairing(payee: "Amazon Marketplace")
  end

  test "N3 rows with a different transacted_at never pair" do
    assert_no_pairing(transacted_at: @posted - 3600)
  end

  test "N3 rows with a different posted date never pair" do
    assert_no_pairing(posted: @posted - 86_400)
  end

  test "N3 rows with a different amount never pair" do
    assert_no_pairing(amount: "-10.26")
  end

  test "N3 rows with a different description never pair" do
    assert_no_pairing(description: "Amazon Mktp")
  end

  # The bridge may send dates as ISO strings, which Simplefin::DateUtils accepts.
  # Compared as String#to_i, every date in a year reads as that year.
  test "N3 ISO dates a day apart never pair" do
    day = Time.at(@posted).utc
    other = day.yday == 1 ? day + 1.day : day - 1.day
    store(row("T1", posted: day.iso8601, transacted_at: day.iso8601))

    import(row("T2", posted: other.iso8601, transacted_at: other.iso8601))

    assert_equal %w[T1 T2], payload_ids.sort
    assert_equal "simplefin_T1", entry_for("T1").external_id
  end

  test "the same instant pairs whether it is sent as epoch seconds or an ISO string" do
    store(row("T1"))
    entry = entry_for("T1")
    iso = Time.at(@posted).utc.iso8601

    import(row("T2", posted: iso, transacted_at: iso))

    assert_equal "simplefin_T2", entry.reload.external_id
    assert_equal [ "T2" ], payload_ids
  end

  # Two syncs can overlap once the first is over five minutes old (Sync::VISIBLE_FOR).
  # Here a second rotation (T2 -> T3) arrives in a sync that read the payload
  # before the first sync's T1 -> T2 committed. Pairing against what it read
  # would re-key nothing and save T3 beside the committed T2: a duplicate.
  test "a sync that read the payload before another committed pairs against what is stored" do
    store(row("T1"))
    entry = entry_for("T1")
    @importer.stubs(:update_inactive_state).with do |sfa, _|
      # The overlapping sync commits between this one's read and its save.
      Entry.where(id: entry.id).update_all(external_id: "simplefin_T2")
      SimplefinAccount.where(id: sfa.id).update_all(raw_transactions_payload: [ row("T2") ])
      true
    end

    import(row("T3"))
    process

    assert_equal [ "simplefin_T3" ], external_ids
    assert_equal [ "T3" ], payload_ids
  end

  test "N4 a fetch that omits older rows never evicts them" do
    old = 120.days.ago.beginning_of_day.to_i
    store(row("OLD1", posted: old, transacted_at: old), row("OLD2", posted: old, transacted_at: old, amount: "-3.00"))

    # Discovery passes start_date: nil, but the bridge still returns recent rows only.
    import(row("R1"))
    process

    assert_equal %w[OLD1 OLD2 R1], payload_ids.sort
    assert_equal %w[simplefin_OLD1 simplefin_OLD2 simplefin_R1], external_ids
  end

  test "N5 a new id that already has an entry is not re-keyed onto" do
    store(row("T1"), row("T2"))
    @sfa.update_column(:raw_transactions_payload, [ row("T1") ])
    entry = entry_for("T1")

    import(row("T2"))

    assert_equal "simplefin_T1", entry.reload.external_id
    assert_equal [ "T2" ], payload_ids
  end

  test "N6 a failed payload save rolls back the re-key" do
    store(row("T1"))
    entry = entry_for("T1")
    SimplefinAccount.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)

    import(row("T2"))

    assert_equal "simplefin_T1", entry.reload.external_id
  end

  test "N7 an unlinked account has its payload re-pointed without touching entries" do
    unlinked = SimplefinAccount.create!(
      simplefin_item: @item, account_id: "ACT-2", name: "Savings", currency: "USD",
      current_balance: 0, account_type: "savings", raw_transactions_payload: [ row("T1") ]
    )

    assert_no_difference -> { Entry.count } do
      import(row("T2"), sfa: unlinked)
    end

    assert_equal [ "T2" ], payload_ids(unlinked)
  end

  test "N8 a row without an id never pairs" do
    store(row("T1"))
    entry = entry_for("T1")

    import(row(nil, fitid: "F1"))

    assert_equal "simplefin_T1", entry.reload.external_id
    assert_includes payload_ids, "T1"
  end

  test "an unchanged id is re-imported onto its own entry" do
    store(row("T1"))
    entry = entry_for("T1")

    assert_no_difference -> { Entry.count } do
      import(row("T1"))
      process
    end

    assert_equal "simplefin_T1", entry.reload.external_id
    assert_equal [ "T1" ], payload_ids
  end

  test "an empty transactions array leaves payload and entries alone" do
    store(row("T1"))

    import

    assert_equal [ "T1" ], payload_ids
    assert_equal [ "simplefin_T1" ], external_ids
  end
end
