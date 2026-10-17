require "test_helper"

# The stale-entry clean-up after processing.
class WiseAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :business)
    @wise_account = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                                     raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 })
    @account = link(@wise_account)
    # Fetched since early December (the clean-up judges only days Sure
    # fetched).
    covered(transfers: "2025-12-08T00:00:00Z", activities: "2025-12-08T00:00:00Z")
  end

  test "deletes the entries no stored row books any more" do
    # Booked by an earlier sync: a payout Wise has since cancelled, and a
    # conversion leg an older routing rule put on this balance.
    stale_entry("wise_transfer_701", date: Date.new(2026, 10, 10))
    stale_entry("wise_interbalance_9001_outflow", date: Date.new(2026, 10, 11))
    store(payout(701, status: "cancelled"), payout(702))

    result = nil
    assert_difference -> { prune_notes.count }, 1 do
      result = process
    end

    assert_equal [ "wise_transfer_702" ], wise_external_ids
    assert_equal [ 1, 2, 0 ], result.values_at(:imported, :pruned, :prune_kept)
    note = prune_notes.sole
    assert_equal "info", note.level
    assert_equal [ "wise_transfer_701", "wise_interbalance_9001_outflow" ], note.metadata["destroyed_external_ids"]
    assert_equal [ @wise_account.id, "EUR" ], note.metadata.values_at("wise_account_id", "currency")
    assert_equal @wise_account.account_provider, note.account_provider
  end

  # An account linked to the balance can hold another connection's Wise
  # history (one removed since, or another profile's). Those entries were
  # booked before the link, so the clean-up leaves them alone even where they
  # overlap the balance's own rows.
  test "keeps the Wise entries an account held before the balance was linked to it" do
    earlier = stale_entry("wise_transfer_88000001", date: Date.new(2026, 10, 11))
    earlier.update_columns(created_at: @wise_account.account_provider.created_at - 1.day)
    stale_entry("wise_transfer_701", date: Date.new(2026, 10, 11))
    store(payout(702))

    result = process

    assert_equal [ 1 ], result.values_at(:pruned)
    assert_equal [ "wise_transfer_702", "wise_transfer_88000001" ], wise_external_ids.sort
  end

  # A split parent and a fee another transfer carries are kept too; deleting
  # them would take the person's split parts or the transfer's fee with them.
  test "keeps and reports the stale entries a person acted on" do
    tag = @family.tags.create!(name: "Receipts")
    bank = Account.create!(family: @family, name: "Bank", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "checking"))
    savings = Account.create!(family: @family, name: "Savings", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "savings"))
    store(payout(702))
    protections = {
      "edited" => ->(entry) { entry.update!(user_modified: true) },
      "import-locked" => ->(entry) { entry.update!(import_locked: true) },
      "with a locked field" => ->(entry) { entry.update!(locked_attributes: { "date" => Time.current.iso8601 }) },
      "with a locked category" => ->(entry) { entry.entryable.update!(locked_attributes: { "category_id" => Time.current.iso8601 }) },
      "with notes" => ->(entry) { entry.update!(notes: "Paid back in cash") },
      "tagged" => ->(entry) { entry.entryable.update!(tag_ids: [ tag.id ]) },
      "with a receipt" => ->(entry) {
        entry.entryable.attachments.attach(io: StringIO.new("%PDF-1.4"), filename: "receipt.pdf", content_type: "application/pdf")
      },
      "reconciled" => ->(entry) { entry.update!(reconciled_at: Time.current) },
      "in a transfer the person confirmed with another bank" => ->(entry) {
        credit = bank.entries.create!(amount: -10, currency: "EUR", date: entry.date, name: "From Wise", entryable: Transaction.new)
        Transfer.create!(inflow_transaction: credit.entryable, outflow_transaction: entry.entryable, status: "confirmed")
      },
      # Parts under the entry without the edit mark Entry#split! also sets.
      "split into parts" => ->(entry) {
        entry.child_entries.create!(account: @account, date: entry.date, name: "Lunch", amount: 10, currency: "EUR", entryable: Transaction.new)
      },
      "the fee of another transfer" => ->(entry) {
        credit = savings.entries.create!(amount: -50, currency: "EUR", date: entry.date, name: "Saved", entryable: Transaction.new)
        debit = bank.entries.create!(amount: 50, currency: "EUR", date: entry.date, name: "To savings", entryable: Transaction.new)
        transfer = Transfer.create!(inflow_transaction: credit.entryable, outflow_transaction: debit.entryable, status: "confirmed")
        entry.entryable.update!(transfer_id: transfer.id)
      }
    }

    protections.each_with_index do |(label, protect), index|
      entry = stale_entry("wise_transfer_#{800 + index}")
      protect.call(entry)

      result = process

      assert Entry.exists?(entry.id), "#{label} entry was deleted"
      assert_equal [ 0, index + 1 ], result.values_at(:pruned, :prune_kept), label
      assert_includes prune_notes.order(:created_at).last.metadata["kept_external_ids"], entry.external_id, label
    end
  end

  # Exclusion does not take an entry out of the balance, and Wise's own links
  # (a suggestion, a conversion linked to another balance of this item) are
  # restored by the next link run where they still apply.
  test "deletes a stale entry that is only excluded, and Wise's own transfer links with stale legs" do
    gbp = @wise_item.wise_accounts.create!(balance_id: "10000002", name: "Wise GBP", currency: "GBP", raw_payload: { "type" => "STANDARD" })
    gbp_account = link(gbp)
    bank = Account.create!(family: @family, name: "Bank", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "checking"))
    excluded = stale_entry("wise_transfer_801", excluded: true)
    eur_leg = stale_entry("wise_interbalance_77_outflow")
    gbp_leg = gbp_account.entries.create!(external_id: "wise_interbalance_77_inflow", source: "wise", amount: -8.6, currency: "GBP",
                                          date: eur_leg.date, name: "Moved", entryable: Transaction.new)
    conversion = Transfer.create!(inflow_transaction: gbp_leg.entryable, outflow_transaction: eur_leg.entryable, status: "confirmed")
    conversion.confirm!
    suggested = stale_entry("wise_transfer_802")
    credit = bank.entries.create!(amount: -10, currency: "EUR", date: suggested.date, name: "From Wise", entryable: Transaction.new)
    suggestion = Transfer.create!(inflow_transaction: credit.entryable, outflow_transaction: suggested.entryable, status: "pending")
    store(payout(702))

    assert_equal 3, process[:pruned]

    assert_not Entry.exists?(excluded.id)
    assert_not Entry.exists?(eur_leg.id)
    assert_not Entry.exists?(suggested.id)
    assert_not Transfer.exists?(conversion.id)
    assert_not Transfer.exists?(suggestion.id)
    assert_equal "standard", gbp_leg.entryable.reload.kind
    assert Entry.exists?(credit.id)
  end

  test "deletes nothing after an incomplete import, without a payload, on a closed balance or when a row fails" do
    entry = stale_entry("wise_transfer_701")
    {
      "an incomplete import" => -> { store(payout(702)); process(import_complete: false) },
      "no payload" => -> { @wise_account.update!(raw_transactions_payload: nil); process },
      "a closed balance" => -> {
        @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("closed_at" => 1.day.ago.utc.iso8601))
        store(payout(702))
        process.tap { @wise_account.update!(raw_payload: @wise_account.raw_payload.except("closed_at")) }
      },
      "a row that fails" => -> { store(payout(702), payout(703).except("created")); process }
    }.each do |label, run|
      result = run.call

      assert Entry.exists?(entry.id), "deleted after #{label}"
      assert_equal 0, result[:pruned], label
    end
    assert_empty prune_notes
  end

  # A shorter history (or an account linked from elsewhere) says nothing
  # about the entries before its first row.
  test "never deletes entries dated before the payload's earliest row" do
    older = stale_entry("wise_transfer_700", date: Date.new(2026, 10, 9))
    same_day = stale_entry("wise_transfer_701", date: Date.new(2026, 10, 10))
    store(payout(702, created: "2026-10-10 06:00:00"))

    process

    assert Entry.exists?(older.id)
    assert_not Entry.exists?(same_day.id)
    assert_equal [ "wise_transfer_701" ], prune_notes.sole.metadata["destroyed_external_ids"]
  end

  # A balance whose re-routed payload is empty (one that only held misrouted
  # copies) is exactly where the misrouted legs sit.
  test "on an empty payload deletes only the entries of rows routing moves" do
    routed = %w[wise_interbalance_5_outflow wise_transfer_6 wise_fee_6 wise_activity_card_1].map { |id| stale_entry(id) }
    statement = stale_entry("wise_statement_TRANSFER-9")
    store

    assert_equal 4, process[:pruned]

    assert routed.none? { |entry| Entry.exists?(entry.id) }
    assert Entry.exists?(statement.id)
  end

  # Beyond the cap, only the entries whose rows a sync that re-fetched the
  # whole history moved out of the payload go
  # (WiseAccount#prune_cap_bypass_ids). That stays pending through incomplete
  # imports and is spent once the clean-up has run; any other stale entry
  # waits. It used to be any number of any stale entries, but only in the
  # re-fetching sync itself, which an incomplete import wasted.
  test "deletes nothing beyond the cap but the entries whose rows a full re-fetch moved out" do
    stale = (801..806).map { |id| stale_entry("wise_transfer_#{id}") }
    store(payout(702))

    result = nil
    assert_difference -> { prune_notes.where(level: "warn").count }, 1 do
      result = process
    end

    assert_equal 0, result[:pruned]
    assert stale.all? { |entry| Entry.exists?(entry.id) }
    note = prune_notes.sole
    assert_equal [ 6, 0 ], note.metadata.values_at("capped_count", "destroyed_count")
    assert_equal stale.map(&:external_id), note.metadata["capped_external_ids"]

    moved = stale.first(5).map(&:external_id) + [ "wise_fee_801" ]
    @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("prune_cap_bypass" => moved))
    assert_equal 0, process(import_complete: false)[:pruned]
    assert_equal moved, @wise_account.reload.prune_cap_bypass_ids

    assert_equal 5, process[:pruned]
    assert_equal %w[wise_transfer_702 wise_transfer_806], wise_external_ids
    note = prune_notes.order(:created_at).last
    assert_equal [ true, 5, [ "wise_transfer_806" ] ], note.metadata.values_at("cap_bypassed", "destroyed_count", "capped_external_ids")
    assert_empty @wise_account.reload.prune_cap_bypass_ids
  end

  test "spends a pending cap bypass whenever the clean-up runs, also with nothing stale" do
    store(payout(702))
    @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("prune_cap_bypass" => [ "wise_transfer_801" ]))

    process

    assert_not @wise_account.reload.raw_payload.key?("prune_cap_bypass")
    assert_empty prune_notes
  end

  # The clean-up used to leave every activity entry of a balance with
  # statement rows alone until the statement rows could take them over. Now
  # the statement row matched to a card payment (WiseItem::StatementMigration)
  # renames its entry before the clean-up, keeping the person's category, and
  # an activity entry no row books is stale like any other.
  test "a statement row takes its card payment's entry over before the stale clean-up" do
    card = stale_entry("wise_activity_card_1")
    card.entryable.update!(locked_attributes: { "category_id" => Time.current.iso8601 })
    forgotten = stale_entry("wise_activity_card_2")
    cancelled = stale_entry("wise_transfer_701")
    store(payout(701, status: "cancelled"), card_payment("card_1").merge("wise_superseded_by" => "wise_statement_CARD-555"),
          statement_row("CARD-555", -12.5, supersedes: { "main" => "wise_activity_card_1" }))

    result = process

    assert_equal [ 1, 2 ], result.values_at(:imported, :pruned)
    assert_equal [ [ card.id, "wise_statement_CARD-555", BigDecimal("12.5") ] ], @account.entries.where(source: "wise").pluck(:id, :external_id, :amount)
    assert card.entryable.reload.locked_attributes.key?("category_id")
    assert_not Entry.exists?(forgotten.id)
    assert_not Entry.exists?(cancelled.id)
    assert_equal({ "renamed_count" => 1 }, rekey_notes.sole.metadata.slice("renamed_count", "replaced_count", "dropped_count"))
  end

  test "renames a transfer's entry and its fee to its statement row's, keeping what a person did" do
    main = stale_entry("wise_transfer_801", amount: 100, notes: "Rent for October")
    fee = stale_entry("wise_fee_801", amount: 2.5)
    store(payout(801).merge("wise_superseded_by" => "wise_statement_TRANSFER-801"),
          statement_row("TRANSFER-801", -102.5, fee: 2.5, supersedes: { "main" => "wise_transfer_801", "fee" => "wise_fee_801" }))

    result = process

    assert_equal [ 1, 1, 0 ], result.values_at(:imported, :skipped, :pruned)
    assert_equal [ [ main.id, "wise_statement_TRANSFER-801", BigDecimal("100") ], [ fee.id, "wise_statement_TRANSFER-801_fee", BigDecimal("2.5") ] ],
                 @account.entries.where(source: "wise").order(:external_id).pluck(:id, :external_id, :amount)
    assert_equal "Rent for October", main.reload.notes
    assert_equal 2, rekey_notes.sole.metadata["renamed_count"]
  end

  # The old migration booked a pay-in again from its statement row, so both
  # entries exist. The one a person acted on (or that sits in a transfer, or
  # that they did not hide) stays under the statement id, the other goes; when
  # a person acted on both, both stay and support is told.
  test "keeps one entry when an older migration booked a transfer twice" do
    acted_on = stale_entry("wise_transfer_901", amount: -50, notes: "Salary")
    duplicate_901 = stale_entry("wise_statement_TRANSFER-901", amount: -50)
    plain = stale_entry("wise_transfer_902", amount: -60)
    linked = stale_entry("wise_statement_TRANSFER-902", amount: -60)
    bank = Account.create!(family: @family, name: "Bank", balance: 0, currency: "EUR", accountable: Depository.new(subtype: "checking"))
    payout_leg = bank.entries.create!(amount: 60, currency: "EUR", date: linked.date, name: "To Wise", entryable: Transaction.new)
    Transfer.create!(inflow_transaction: linked.entryable, outflow_transaction: payout_leg.entryable, status: "pending")
    kept_legacy = stale_entry("wise_transfer_903", amount: -70, notes: "Gift")
    kept_statement = stale_entry("wise_statement_TRANSFER-903", amount: -70, user_modified: true)
    shown = stale_entry("wise_transfer_904", amount: -80)
    hidden = stale_entry("wise_statement_TRANSFER-904", amount: -80, excluded: true)
    rows = [ 901, 902, 903, 904 ].flat_map do |id|
      [ pay_in(id).merge("wise_superseded_by" => "wise_statement_TRANSFER-#{id}"),
        statement_row("TRANSFER-#{id}", 50 + (id - 901) * 10, supersedes: { "main" => "wise_transfer_#{id}", "fee" => "wise_fee_#{id}" }) ]
    end
    store(*rows)

    process

    assert_equal acted_on.id, @account.entries.find_by!(external_id: "wise_statement_TRANSFER-901").id
    assert_not Entry.exists?(duplicate_901.id)
    assert_not Entry.exists?(plain.id)
    assert_equal linked.id, @account.entries.find_by!(external_id: "wise_statement_TRANSFER-902").id
    assert Entry.exists?(kept_legacy.id)
    assert Entry.exists?(kept_statement.id)
    assert_equal shown.id, @account.entries.find_by!(external_id: "wise_statement_TRANSFER-904").id
    assert_not Entry.exists?(hidden.id)
    note = rekey_notes.sole
    assert_equal "warn", note.level
    assert_equal [ 2, 1, 1 ], note.metadata.values_at("replaced_count", "dropped_count", "kept_both_count")
    assert_equal [ "wise_transfer_903" ], note.metadata["kept_both_external_ids"]
  end

  # The payload's rows start in September, but the item holds the row that
  # booked an older entry here (WiseAccount#prune_cap_bypass_ids), so that
  # entry is judged too.
  test "judges an entry dated before the payload's earliest row when a row the item holds booked it" do
    explained = stale_entry("wise_interbalance_77_inflow", date: Date.new(2025, 12, 20), amount: -860)
    unexplained = stale_entry("wise_transfer_77001", date: Date.new(2025, 12, 21))
    @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("prune_cap_bypass" => [ "wise_interbalance_77_inflow" ]))
    store(payout(702, created: "2026-09-01 12:00:00"))

    assert_equal 1, process[:pruned]
    assert_not Entry.exists?(explained.id)
    assert Entry.exists?(unexplained.id)
  end

  # Every jar move names an id its other side could have had; the account's
  # ids are read once for them all, not once per row.
  test "reads the account's entry ids once for the renames of a whole payload" do
    moves = (1..5).map { |i| jar_move("880#{i}", "To <strong>Jar</strong>") }
    stale_entry("wise_interbalance_8801_inflow", amount: -500)
    store(*moves)
    lookups = []
    callback = ->(*, payload) { lookups << payload[:sql] if payload[:sql].match?(/FROM "entries" WHERE .*"entries"\."external_id" IN/) }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { process }

    assert_empty lookups
    assert_equal [ "wise_interbalance_8801_outflow", "wise_interbalance_8802_outflow" ], wise_external_ids.first(2)
  end

  # Another processor may hold the balance's lock once its session ended, so
  # nothing is deleted then; the next sync cleans up.
  test "deletes nothing once the balance's processing lock was lost" do
    stale = stale_entry("wise_transfer_701")
    store(payout(702))
    @wise_account.stubs(:processing_lock_lost?).returns(true)

    result = WiseAccount::Transactions::Processor.new(@wise_account, import_complete: true).process

    assert_equal [ 1, 0 ], result.values_at(:imported, :pruned)
    assert Entry.exists?(stale.id)
  end

  test "deletes neither of two entries for one transfer after an incomplete import" do
    legacy = stale_entry("wise_transfer_904", amount: -50)
    booked = stale_entry("wise_statement_TRANSFER-904", amount: -50)
    store(pay_in(904).merge("wise_superseded_by" => "wise_statement_TRANSFER-904"),
          statement_row("TRANSFER-904", 50, supersedes: { "main" => "wise_transfer_904" }))

    process(import_complete: false)

    assert Entry.exists?(legacy.id)
    assert Entry.exists?(booked.id)
    assert_equal 1, rekey_notes.sole.metadata["deferred_count"]
  end

  # The row fails rather than book a second entry beside the old one; the
  # next sync tries again (and nothing is pruned meanwhile).
  test "a statement row whose entry cannot be renamed fails without booking a second entry" do
    old = stale_entry("wise_transfer_905", amount: 100)
    old.update_column(:date, 40.years.ago.to_date)
    store(payout(905).merge("wise_superseded_by" => "wise_statement_TRANSFER-905"),
          statement_row("TRANSFER-905", -100, supersedes: { "main" => "wise_transfer_905" }))

    result = process

    assert_equal [ 1, 0 ], result.values_at(:failed, :pruned)
    assert_equal [ "wise_transfer_905" ], wise_external_ids
    assert_equal 1, rekey_notes.sole.metadata["failed_count"]
  end

  # Sure booked a jar withdrawal on the balance's "_outflow" side whatever way
  # the money went. Its leg is the inflow now, and the entry is renamed in
  # place, keeping what a person did to it, rather than deleted as stale and
  # booked again.
  test "renames a jar withdrawal's entry to the side it is booked on" do
    old = stale_entry("wise_interbalance_5501_outflow", amount: 500, notes: "Back from savings")
    store(jar_move("5501", "To <strong>EUR</strong>"))

    result = process

    assert_equal [ 1, 0 ], result.values_at(:imported, :pruned)
    assert_equal [ [ old.id, "wise_interbalance_5501_inflow", BigDecimal("-500") ] ],
                 @account.entries.where(source: "wise").pluck(:id, :external_id, :amount)
    assert_equal "Back from savings", old.reload.notes
    assert_equal({ "operation" => "leg_side_rekey", "renamed_count" => 1 },
                 DebugLogEntry.where(provider_key: "wise").sole.metadata.slice("operation", "renamed_count", "replaced_count"))

    # Booked on its side, the next run renames nothing.
    assert_no_difference -> { DebugLogEntry.count } do
      process
    end
  end

  # A family zone tzdata does not know (Family checks it only when it changes)
  # failed every Wise row; they are dated in UTC instead, and support is told
  # once.
  test "books every kind of row in UTC for a family whose stored time zone is unknown" do
    @family.update_column(:timezone, "Invalid/Timezone")
    store(payout(702, created: "2026-10-10 23:30:00"), card_payment("card_1").merge("createdOn" => "2026-10-10T23:40:00Z"),
          statement_row("CARD-555", -12.5).merge("date" => "2026-10-10T23:50:00Z"))

    result = nil
    assert_difference -> { DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "time_zone").count }, 1 do
      result = process
    end

    assert_equal [ 3, 0 ], result.values_at(:imported, :failed)
    assert_equal [ [ "wise_activity_card_1", Date.new(2026, 10, 10) ], [ "wise_statement_CARD-555", Date.new(2026, 10, 10) ],
                   [ "wise_transfer_702", Date.new(2026, 10, 10) ] ],
                 @account.entries.where(source: "wise").order(:external_id).pluck(:external_id, :date)
  end

  # An account linked to the balance can hold an earlier connection's history
  # from before the window Sure fetched, which no row will ever book again, so
  # the clean-up judges only days Sure fetched every row of an entry's kind: a
  # transfer's entries also need its activities' days, a statement row's the
  # balance's statements.
  test "deletes only entries dated where Sure fetched every row of their kind" do
    covered(transfers: "2026-10-11T00:00:00Z", activities: "2026-10-10T09:00:00Z", statements: "2026-10-11T00:00:00Z")
    kinds = %w[wise_transfer_80 wise_interbalance_80_outflow wise_statement_TRANSFER-80]
    earlier = kinds.map { |id| stale_entry("#{id}1", date: Date.new(2026, 10, 10)) }
    fetched = kinds.map { |id| stale_entry("#{id}2", date: Date.new(2026, 10, 11)) }
    store(payout(702, created: "2026-10-09 12:00:00"))

    assert_equal 3, process[:pruned]

    assert earlier.all? { |entry| Entry.exists?(entry.id) }
    assert fetched.none? { |entry| Entry.exists?(entry.id) }
  end

  test "judges an empty payload by the same days, and nothing without coverage" do
    covered(transfers: "2026-10-12T00:00:00Z", activities: "2026-10-12T00:00:00Z")
    earlier = stale_entry("wise_activity_card_1", date: Date.new(2026, 10, 11))
    fetched = stale_entry("wise_activity_card_2", date: Date.new(2026, 10, 12))
    store

    assert_equal 1, process[:pruned]
    assert Entry.exists?(earlier.id)
    assert_not Entry.exists?(fetched.id)

    @wise_item.update!(raw_payload: nil)
    @wise_account.update!(raw_payload: @wise_account.raw_payload.merge("prune_cap_bypass" => [ "wise_activity_card_3" ]))
    unjudged = stale_entry("wise_activity_card_3")
    [ [], [ payout(702) ] ].each do |rows|
      store(*rows)
      assert_equal 0, process[:pruned]
    end
    assert Entry.exists?(unjudged.id)
    assert_equal [ "wise_activity_card_3" ], @wise_account.reload.prune_cap_bypass_ids, "a clean-up that judged nothing spends no bypass"
  end

  test "an empty payload without a complete import is processed as before" do
    store

    assert_equal({ success: true, total: 0, imported: 0, skipped: 0, failed: 0, errors: [], pruned: 0, prune_kept: 0 },
                 process(import_complete: false))
  end

  private

    def link(wise_account)
      account = Account.create!(family: @family, name: wise_account.name, balance: 0, currency: wise_account.currency,
                                accountable: Depository.new(subtype: "checking"))
      AccountProvider.create!(account: account, provider: wise_account)
      account
    end

    # A same-currency payout to someone else, booked as wise_transfer_<id>.
    def payout(id, status: "outgoing_payment_sent", created: "2026-10-10 12:00:00")
      { "id" => id, "targetAccount" => 4242, "sourceCurrency" => "EUR", "targetCurrency" => "EUR",
        "sourceValue" => 25.0, "targetValue" => 25.0, "status" => status, "created" => created }
    end

    # An entry an earlier sync booked from a row no longer stored here.
    def stale_entry(external_id, date: Date.new(2026, 10, 12), amount: 10, **attributes)
      @account.entries.create!(external_id: external_id, source: "wise", amount: amount, currency: "EUR", date: date,
                               name: "Wise row", entryable: Transaction.new, **attributes)
    end

    def store(*rows)
      @wise_account.update!(raw_transactions_payload: rows)
    end

    # What the importer records once it fetched a source in full since the
    # given time (ISO-8601 UTC); statements are the balance's own.
    def covered(transfers: nil, activities: nil, statements: nil)
      window = ->(from) { { "from" => from, "through" => "2026-10-17T12:00:00Z", "version" => WiseItem::COVERAGE_VERSION } }
      @wise_item.update!(raw_payload: { "coverage" => { "transfers" => transfers, "activities" => activities }.compact.transform_values(&window) })
      @wise_account.update!(raw_payload: @wise_account.raw_payload.except("statements_coverage")
                                                   .merge({ "statements_coverage" => statements && window.call(statements).except("version") }.compact))
    end

    def process(import_complete: true)
      WiseAccount::Transactions::Processor.new(@wise_account.reload, import_complete: import_complete).process
    end

    def wise_external_ids
      @account.entries.where(source: "wise").order(:external_id).pluck(:external_id)
    end

    def prune_notes
      DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "prune")
    end

    def rekey_notes
      DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "statement_rekey")
    end

    # A same-currency transfer into the account recipient (a pay-in).
    def pay_in(id)
      payout(id).merge("targetAccount" => 99999001)
    end

    # A move between this balance and a jar, both in EUR.
    def jar_move(resource_id, title)
      { "id" => "interbalance_#{resource_id}", "type" => "INTERBALANCE", "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title, "primaryAmount" => "500 EUR", "status" => "COMPLETED", "createdOn" => "2026-10-10T08:00:00Z" }
    end

    def card_payment(id)
      { "id" => id, "type" => "CARD_PAYMENT", "resource" => { "type" => "CARD_TRANSACTION", "id" => "555" },
        "title" => "<strong>Merchant</strong>", "primaryAmount" => "12.50 EUR", "secondaryAmount" => "", "status" => "COMPLETED",
        "createdOn" => "2026-10-10T08:00:00Z" }
    end

    # supersedes: the entries the importer matched to it (WiseItem::StatementMigration).
    def statement_row(reference, value, fee: nil, supersedes: nil)
      { "type" => value.negative? ? "DEBIT" : "CREDIT", "date" => "2026-10-10T08:00:00Z",
        "amount" => { "value" => value, "currency" => "EUR" }, "totalFees" => ({ "value" => fee, "currency" => "EUR" } if fee),
        "referenceNumber" => reference, "wise_statement" => true, "wise_supersedes" => supersedes }.compact
    end
end
