# frozen_string_literal: true

require "test_helper"

# A bank can re-issue a transaction under a new id: the description is
# shortened and a new id appears while the old one stops being served, or the
# bank sends no ids for a while and Fiskil generates `bank_tx_s_` ones. Each
# test syncs through the importer and then the processor, the way a real sync
# does, so a row left in the snapshot shows up as an entry.
class RedbarkItem::ImporterReissuedIdsTest < ActiveSupport::TestCase
  ORIGINAL = "TRANSFER 1000000001  FROM 000-111-222333"
  SHORTENED = "TRANSFER 1000000001  FROM 000-111-222"

  setup do
    @redbark_item = redbark_items(:one)
    @redbark_account = redbark_accounts(:savings_account)
    @family = @redbark_item.family
    @account = @family.accounts.create!(name: "Card", balance: 0, currency: "AUD", accountable: CreditCard.new)
    @redbark_account.ensure_account_provider!(@account)
    @redbark_account.reload

    @date = (Date.current - 2).to_s
    # Incremental window: last_synced_at - 7 days
    @redbark_item.stubs(:last_synced_at).returns(Time.current)
  end

  test "a shortened description moves the existing entry to the new id" do
    entry = import_original(row("A", ORIGINAL, reference: "0"))
    category = categories(:income)
    entry.transaction.update!(category: category)

    assert_no_difference -> { @account.entries.count } do
      sync([ row("B", SHORTENED, reference: "75400000000000000000001") ])
    end

    entry.reload
    assert_equal "redbark_B", entry.external_id
    assert_equal category, entry.transaction.category
    assert_equal SHORTENED, entry.notes
    assert_equal [ "B" ], snapshot_ids
  end

  test "a second sync after the move re-creates nothing" do
    import_original(row("A", ORIGINAL, reference: "0"))
    fetched = [ row("B", SHORTENED, reference: "75400000000000000000001") ]
    sync(fetched)

    assert_no_difference -> { @account.entries.count } do
      sync(fetched)
    end
    assert_nil @account.entries.find_by(external_id: "redbark_A")
  end

  test "equal real references move the entry whatever the descriptions" do
    entry = import_original(row("A", "CARD PURCHASE 4411", reference: "0522100624"))

    assert_no_difference -> { @account.entries.count } do
      sync([ row("B", "Coffee Shop Sydney", reference: "0522100624") ])
    end
    assert_equal "redbark_B", entry.reload.external_id
  end

  test "a generated id becomes an alias and the restored id still matches" do
    entry = import_original(row("A", "FALLS RESTAURANT 94.06"))

    assert_no_difference -> { @account.entries.count } do
      sync([ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ])
    end
    entry.reload
    assert_equal "redbark_A", entry.external_id
    assert_equal [ "bank_tx_s_X" ], entry.transaction.extra.dig("redbark", "alias_ids")
    assert_not_includes snapshot_ids, "bank_tx_s_X"

    assert_no_difference -> { @account.entries.count } do
      sync([ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ])
      sync([ row("A", "FALLS RESTAURANT 94.06") ])
    end
    assert_equal "redbark_A", entry.reload.external_id
  end

  test "an aliased id served beside the restored one adds nothing" do
    import_original(row("A", "FALLS RESTAURANT 94.06"))
    sync([ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ])

    assert_no_difference -> { @account.entries.count } do
      sync([ row("A", "FALLS RESTAURANT 94.06"), row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ])
    end
    assert_not_includes snapshot_ids, "bank_tx_s_X"
  end

  test "a generated id with no entry to alias is imported" do
    @redbark_account.update!(raw_transactions_payload: [ row("A", "FALLS RESTAURANT 94.06") ])

    assert_difference -> { @account.entries.count }, 1 do
      sync([ row("bank_tx_s_X", "FALLS RESTAURANT 94.06") ])
    end
    assert @account.entries.exists?(external_id: "redbark_bank_tx_s_X")
  end

  test "genuine look-alikes both still served stay two entries" do
    import_original(row("A", "FALLS RESTAURANT", reference: "476053"))

    assert_difference -> { @account.entries.count }, 1 do
      sync([ row("A", "FALLS RESTAURANT", reference: "476053"), row("C", "FALLS RESTAURANT", reference: "199002") ])
    end
    assert @account.entries.exists?(external_id: "redbark_A")
    assert @account.entries.exists?(external_id: "redbark_C")
  end

  test "an excluded entry moves to the new id and keeps its name and exclusion" do
    entry = import_original(row("A", ORIGINAL, reference: "0"))
    entry.update!(excluded: true)
    name_before = entry.name
    notes_before = entry.notes

    assert_no_difference -> { @account.entries.count } do
      sync([ row("B", SHORTENED, reference: "75400000000000000000001") ])
    end

    entry.reload
    assert_equal "redbark_B", entry.external_id
    assert entry.excluded?
    assert_equal name_before, entry.name
    assert_equal notes_before, entry.notes
  end

  test "a user-modified entry moves to the new id and keeps its name" do
    entry = import_original(row("A", ORIGINAL, reference: "0"))
    entry.update!(name: "Card repayment", user_modified: true)

    sync([ row("B", SHORTENED, reference: "75400000000000000000001") ])

    entry.reload
    assert_equal "redbark_B", entry.external_id
    assert_equal "Card repayment", entry.name
  end

  test "an existing entry for the new id blocks the move" do
    original = import_original(row("A", ORIGINAL, reference: "0"))
    copy = @account.entries.create!(
      name: "Copy", date: @date, amount: -50, currency: "AUD", external_id: "redbark_B", source: "redbark",
      entryable: Transaction.new
    )

    assert_no_difference -> { @account.entries.count } do
      assert_difference -> { DebugLogEntry.where(provider_key: "redbark").count }, 1 do
        sync([ row("B", SHORTENED, reference: "75400000000000000000001") ])
      end
    end
    assert_equal "redbark_A", original.reload.external_id
    assert_equal "redbark_B", copy.reload.external_id
    assert_equal [ "B" ], snapshot_ids
  end

  test "a changed description on the same id pairs nothing" do
    entry = import_original(row("A", "GP75122326249061325002498 399.97ZA"))

    assert_no_difference -> { @account.entries.count } do
      sync([ row("A", "GP399.97 ZAR", reference: "75122326249061325002498") ])
    end
    entry.reload
    assert_equal "redbark_A", entry.external_id
    assert_equal "GP399.97 ZAR", entry.notes
  end

  test "the reference is stored on the transaction" do
    import_original(row("A", ORIGINAL, reference: "0"))
    sync([ row("A", ORIGINAL, reference: "75400000000000000000001") ])

    extra = @account.entries.find_by(external_id: "redbark_A").transaction.extra["redbark"]
    assert_equal "75400000000000000000001", extra["reference"]
  end

  private

    def row(id, description, reference: nil, amount: "50.00", status: "posted")
      { "id" => id, "status" => status, "date" => @date, "amount" => amount, "description" => description, "reference" => reference }.compact
    end

    def import_original(original)
      @redbark_account.update!(raw_transactions_payload: [ original ])
      RedbarkAccount::Transactions::Processor.new(@redbark_account).process
        @account.entries.find_by!(external_id: "redbark_#{original["id"]}")
    end

    def sync(fetched)
      provider = mock("redbark_provider")
      provider.stubs(:list_connections).returns([])
      provider.stubs(:get_transactions).returns(fetched)

      RedbarkItem::Importer.new(@redbark_item, redbark_provider: provider).send(:import_transactions, @redbark_account)
      @redbark_account.reload
      RedbarkAccount::Transactions::Processor.new(@redbark_account).process
    end

    def snapshot_ids
      @redbark_account.reload.raw_transactions_payload.map { |t| t["id"] }
    end
end
