require "test_helper"

class EnableBankingItem::ImporterBookedReferencesTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @account.update!(currency: "EUR")
    @item = EnableBankingItem.create!(
      family: @account.family,
      name: "Test bank",
      country_code: "ES",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: 1.month.ago.to_date
    )
    @provider_account = EnableBankingAccount.create!(
      enable_banking_item: @item,
      name: "Current account",
      uid: "test-booked-references",
      account_id: "65b1cf69-2bb8-4ea5-b059-73621df32098",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
    @provider = mock()
    @provider.stubs(:get_session).returns(accounts: [ @provider_account.uid ])
    @provider.stubs(:get_account_balances).returns(
      balances: [ { balance_type: "CLBD", balance_amount: { amount: "100.00", currency: "EUR" } } ]
    )
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: [])
    @importer = EnableBankingItem::Importer.new(@item, enable_banking_provider: @provider)
  end

  test "imports both booked operations when their bank references are trusted" do
    @item.update!(preserve_distinct_booked_references: true)
    rows = JSON.parse(file_fixture("enable_banking/distinct_booked_top_ups.json").read)
    rows.each do |tx|
      tx["booking_date"] = tx["value_date"] = Date.current.to_s
    end
    provide_booked_rows(rows)

    import_and_process

    assert_equal %w[reference-a reference-b], stored_references
    assert_equal %w[enable_banking_reference-a enable_banking_reference-b], imported_entries.pluck(:external_id).sort
    assert_equal [ BigDecimal("12.00"), BigDecimal("12.00") ], imported_entries.order(:external_id).pluck(:amount)
  end

  test "retains content deduplication by default for banks that repeat operations under different references" do
    assert_not @item.preserve_distinct_booked_references?
    provide_booked_rows([ booked("reference-a"), booked("reference-b") ])

    import_and_process

    assert_equal [ "reference-a" ], stored_references
    assert_equal 1, imported_entries.count
  end

  test "preserves distinct references when the booked endpoint omits status" do
    @item.update!(preserve_distinct_booked_references: true)
    rows = [ booked("reference-a"), booked("reference-b") ].map { |tx| tx.except(:status) }
    provide_booked_rows(rows)

    import_and_process

    assert_equal %w[reference-a reference-b], stored_references
    assert_equal 2, imported_entries.count
    assert_equal BigDecimal("24.00"), imported_entries.sum(:amount)

    assert_no_difference -> { imported_entries.count } do
      import_and_process
    end
  end

  test "does not treat rows without status from the pending endpoint as booked" do
    @item.update!(preserve_distinct_booked_references: true)
    @importer.stubs(:include_pending?).returns(true)
    provide_booked_rows([])
    rows = [ booked("pending-a"), booked("pending-b") ].map { |tx| tx.except(:status) }
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: rows)

    import_and_process

    assert_equal [ "pending-a" ], stored_references
    assert_equal 1, imported_entries.count
    assert imported_entries.sole.transaction.pending?
  end

  test "adds only a missing reference and preserves reviewed entries across repeated imports" do
    rows = [ booked("reference-a"), booked("reference-b") ]
    provide_booked_rows(rows)
    import_and_process
    original = imported_entries.sole
    original.update!(notes: "Reviewed transaction")
    original.mark_user_modified!

    @item.update!(preserve_distinct_booked_references: true)
    provide_booked_rows(rows.reverse)

    assert_difference -> { imported_entries.count }, 1 do
      import_and_process
    end
    ids = imported_entries.pluck(:id).sort
    assert_equal "Reviewed transaction", original.reload.notes

    assert_no_difference -> { imported_entries.count } do
      import_and_process
    end
    assert_equal ids, imported_entries.pluck(:id).sort
    assert_equal %w[reference-a reference-b], stored_references
    assert_equal "Reviewed transaction", original.reload.notes
  end

  test "imports a repeated reference only once when pages overlap" do
    @item.update!(preserve_distinct_booked_references: true)
    first = booked("reference-a")
    second = booked("reference-b")
    @provider.stubs(:get_account_transactions)
             .with(has_entries(transaction_status: "BOOK", continuation_key: nil))
             .returns(transactions: [ first ], continuation_key: "next-page")
    @provider.stubs(:get_account_transactions)
             .with(has_entries(transaction_status: "BOOK", continuation_key: "next-page"))
             .returns(transactions: [ first.deep_stringify_keys, second ])

    import_and_process

    assert_equal %w[reference-a reference-b], stored_references
    assert_equal 2, imported_entries.count
  end

  test "prefers booked references over matching pending copies regardless of response order" do
    @item.update!(preserve_distinct_booked_references: true)
    @importer.stubs(:include_pending?).returns(true)
    pending = booked("pending-reference").merge(status: "PDNG")
    provide_booked_rows([ pending, booked("reference-a"), booked("reference-b") ])
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: [ pending ])

    import_and_process

    assert_equal %w[reference-a reference-b], stored_references
    assert_equal 2, imported_entries.count
    assert imported_entries.all? { |entry| !entry.transaction.pending? }
  end

  test "preserves two distinct incoming top-ups as separate ledger credits" do
    @item.update!(preserve_distinct_booked_references: true)
    rows = [ booked("reference-a"), booked("reference-b") ].map { |tx| tx.merge(credit_debit_indicator: "CRDT") }
    provide_booked_rows(rows)

    import_and_process

    assert_equal 2, imported_entries.count
    assert_equal BigDecimal("-24.00"), imported_entries.sum(:amount)
  end

  test "settles a previously imported pending operation without losing the second booked reference" do
    @item.update!(preserve_distinct_booked_references: true)
    @importer.stubs(:include_pending?).returns(true)
    provide_booked_rows([])
    pending = booked("pending-reference").merge(status: "PDNG")
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: [ pending ])
    import_and_process
    original = imported_entries.sole
    assert original.transaction.pending?

    provide_booked_rows([ booked("reference-a"), booked("reference-b") ])
    @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "PDNG")).returns(transactions: [])

    assert_difference -> { imported_entries.count }, 1 do
      import_and_process
    end

    assert_equal %w[enable_banking_reference-a enable_banking_reference-b], imported_entries.pluck(:external_id).sort
    assert imported_entries.exists?(original.id)
    assert imported_entries.all? { |entry| !entry.transaction.pending? }

    assert_no_difference -> { imported_entries.count } do
      import_and_process
    end
  end

  test "retains fallback matching when the bank supplies no references" do
    @item.update!(preserve_distinct_booked_references: true)
    row = booked(nil).merge(creditor: { name: "Synthetic merchant" })
    provide_booked_rows([ row, row.deep_dup ])

    import_and_process

    assert_equal 1, imported_entries.count
    assert_match(/\Aenable_banking_content_/, imported_entries.sole.external_id)
  end

  test "claims an identifierless predecessor once when two booked references arrive" do
    @item.update!(preserve_distinct_booked_references: true)
    row = booked(nil).merge(creditor: { name: "Synthetic merchant" })
    provide_booked_rows([ row ])
    import_and_process
    original = imported_entries.sole
    original.update!(notes: "Reviewed before settlement")
    original.mark_user_modified!
    provide_booked_rows([ row.merge(entry_reference: "reference-a"), row.merge(entry_reference: "reference-b") ])

    assert_difference -> { imported_entries.count }, 1 do
      import_and_process
    end

    assert_equal "Reviewed before settlement", original.reload.notes
    assert_equal %w[enable_banking_reference-a enable_banking_reference-b], imported_entries.pluck(:external_id).sort

    assert_no_difference -> { imported_entries.count } do
      import_and_process
    end
  end

  private
    def booked(reference)
      {
        entry_reference: reference,
        transaction_id: nil,
        booking_date: Date.current.to_s,
        value_date: Date.current.to_s,
        transaction_amount: { amount: "12.00", currency: "EUR" },
        credit_debit_indicator: "DBIT",
        remittance_information: [ "Synthetic card top-up" ],
        status: "BOOK"
      }
    end

    def provide_booked_rows(rows)
      @provider.stubs(:get_account_transactions).with(has_entries(transaction_status: "BOOK")).returns(transactions: rows)
    end

    def import_and_process
      result = @importer.import
      assert result[:success], result.inspect
      processing = EnableBankingAccount::Transactions::Processor.new(@provider_account.reload).process
      assert processing[:success], processing.inspect
    end

    def stored_references
      @provider_account.reload.raw_transactions_payload.map { |tx| tx["entry_reference"] }.sort
    end

    def imported_entries
      @account.entries.where(source: "enable_banking", entryable_type: "Transaction")
    end
end
