require "test_helper"

# The stale-entry clean-up after processing.
class WiseAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(family: @family, name: "Test Wise", token: "test_token", profile_id: "123", profile_type: :business)
    @wise_account = @wise_item.wise_accounts.create!(balance_id: "10000001", name: "Wise EUR", currency: "EUR",
                                                     raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 })
    @account = link(@wise_account)
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

  test "deletes nothing when more entries are stale than the cap allows, except right after a full re-fetch" do
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

    assert_equal 6, process(coverage_upgraded: true)[:pruned]
    assert stale.none? { |entry| Entry.exists?(entry.id) }
    assert prune_notes.order(:created_at).last.metadata["cap_bypassed"]
  end

  # Until the statement rows take their entries over, the card payments of a
  # balance that gained statements keep their entries.
  test "leaves the activity entries of a balance with statement rows alone" do
    card = stale_entry("wise_activity_card_1")
    cancelled = stale_entry("wise_transfer_701")
    store(payout(701, status: "cancelled"),
          { "type" => "DEBIT", "date" => "2026-10-10T08:00:00Z", "amount" => { "value" => -12.5, "currency" => "EUR" },
            "referenceNumber" => "CARD-555", "wise_statement" => true })

    assert_equal 1, process[:pruned]

    assert Entry.exists?(card.id)
    assert_not Entry.exists?(cancelled.id)
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
    def stale_entry(external_id, date: Date.new(2026, 10, 12), **attributes)
      @account.entries.create!(external_id: external_id, source: "wise", amount: 10, currency: "EUR", date: date,
                               name: "Wise row", entryable: Transaction.new, **attributes)
    end

    def store(*rows)
      @wise_account.update!(raw_transactions_payload: rows)
    end

    def process(import_complete: true, coverage_upgraded: false)
      WiseAccount::Transactions::Processor.new(@wise_account.reload, import_complete: import_complete,
                                                                     coverage_upgraded: coverage_upgraded).process
    end

    def wise_external_ids
      @account.entries.where(source: "wise").order(:external_id).pluck(:external_id)
    end

    def prune_notes
      DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "prune")
    end
end
