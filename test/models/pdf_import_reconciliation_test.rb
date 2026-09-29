require "test_helper"

# The behaviour issue #1379 actually asked for: a statement should only offer
# transactions that are not already recorded, and should mark the rest reconciled.
class PdfImportReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family = @account.family
    @statement = create_statement
    @import = PdfImport.create_from_statement!(statement: @statement)
    @import.update!(document_type: "bank_statement")
    @date = Date.current
  end

  # Extractor convention: negative for debits, positive for credits. Import
  # signage ("inflows_positive") flips that into Entry convention, where an
  # expense is positive.
  def extracted(date:, amount:, name:)
    { "date" => date.to_s, "amount" => amount.to_s, "name" => name }
  end

  test "rows are only generated for transactions that are not already recorded" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "COFFEE SHOP"),
      extracted(date: @date, amount: -12, name: "BOOKSTORE")
    ] })

    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_equal "BOOKSTORE", @import.rows.sole.name
  end

  test "the already-recorded transaction is marked reconciled against the statement" do
    existing = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "COFFEE SHOP") ] })
    @import.generate_rows_from_extracted_data

    existing.reload
    assert_equal :reconciled, existing.reconciliation_state
    assert_equal @statement, existing.reconciled_by_statement
    assert_equal [ existing ], @import.reconciled_entries.to_a
  end

  test "a provider-synced transaction counts as already recorded" do
    synced = create_transaction(
      account: @account, date: @date, amount: 50, name: "COFFEE", external_id: "plaid-1", source: "plaid"
    )

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee Shop") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 0, @import.reload.rows_count
    assert_equal :reconciled, synced.reload.reconciliation_state
  end

  test "a statement date a day or two off the recorded date still matches" do
    create_transaction(account: @account, date: @date - 2, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 0, @import.reload.rows_count
  end

  test "two identical statement lines do not both match one recorded transaction" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -50, name: "Coffee")
    ] })
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count, "the second identical line is genuinely new"
  end

  test "with no account assigned every transaction is offered" do
    @import.update!(account: nil)
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
  end

  test "a row whose date cannot be parsed is offered rather than dropped" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => "not-a-date", "amount" => "-50", "name" => "Mystery" }
    ] })

    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
  end

  test "a row whose amount cannot be parsed is offered with its raw value intact" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => @date.to_s, "amount" => "not-a-number", "name" => "Mystery" }
    ] })

    @import.generate_rows_from_extracted_data

    row = @import.reload.rows.sole
    assert_equal 1, @import.rows_count
    # Stored verbatim rather than coerced to 0, so the review step shows the user
    # what the statement actually said.
    assert_equal "not-a-number", row.amount
  end

  test "reassigning the account re-judges the rows and releases the old reconciliation" do
    other = @family.accounts.create!(
      name: "Second Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    on_first = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 0, @import.reload.rows_count

    @import.assign_account!(other)

    assert_not on_first.reload.reconciled?, "the old account's entry is no longer evidence-backed"
    assert_equal 1, @import.reload.rows_count, "nothing on the new account matches, so it is offered"
  end

  test "extract_transactions stores string keys so rows can actually be generated" do
    provider = mock("llm_provider")
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.stubs(:extract_bank_statement).returns(
      OpenStruct.new(success?: true, data: { transactions: [ { date: @date.to_s, amount: "-5.0", name: "Coffee" } ] })
    )
    @import.stubs(:pdf_file_content).returns("fake-pdf")

    @import.extract_transactions

    # Without deep_stringify_keys this reads back empty and no rows are built.
    assert_equal 1, @import.extracted_transactions.size
    assert_equal "Coffee", @import.extracted_transactions.first["name"]
  end

  test "publishing does not re-match a row against an entry row generation already consumed" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    # Two identical statement lines, one existing transaction: the first line
    # reconciles against it, the second is genuinely new and must be created.
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -50, name: "Coffee")
    ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count

    assert_difference -> { @account.entries.count }, 1 do
      @import.import!
    end
  end

  test "assigning an account that reconciles every row completes the import" do
    @import.update!(account: nil, status: :pending)
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")

    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count, "nothing matches while no account is assigned"

    @import.assign_account!(@account)

    @import.reload
    assert_equal 0, @import.rows_count
    assert @import.complete?, "a fully reconciled import must finish rather than sit at pending with no rows"
  end

  test "assigning an account that matches nothing returns the import to pending" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :complete)

    other = @family.accounts.create!(
      name: "Untouched Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    # complete but nothing of its own committed: still the user's to re-target.
    assert @import.assign_account!(other)

    @import.reload
    assert_equal 1, @import.rows_count
    assert @import.pending?
  end

  test "a row that cannot be evaluated is recorded in the debug log" do
    @import.update!(extracted_data: { "transactions" => [
      { "date" => "not-a-date", "amount" => "-50", "name" => "Mystery" }
    ] })

    assert_difference "DebugLogEntry.count", 1 do
      @import.generate_rows_from_extracted_data
    end

    logged = DebugLogEntry.last
    assert_equal "import", logged.category
    assert_equal @family, logged.family
    assert_equal @import.id, logged.metadata["import_id"]
  end

  test "regenerating rows twice does not collide on source row numbers" do
    # insert_all! leaves the rows association stale, so a second generation on
    # the same in-memory record used to re-insert source_row_number 1.
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12, name: "Bookstore") ] })

    @import.generate_rows_from_extracted_data
    @import.generate_rows_from_extracted_data

    assert_equal 1, @import.reload.rows_count
    assert_equal 1, @import.rows.count
  end

  test "releasing reconciliations leaves another account's evidence intact" do
    other = @family.accounts.create!(
      name: "Sibling Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    # Same statement, evidence recorded against a second account by another import.
    on_other = create_transaction(account: other, date: @date, amount: 99, name: "Elsewhere")
    on_other.mark_reconciled!(statement: @statement)

    on_first = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert on_first.reload.reconciled?

    @import.assign_account!(other)

    # Both fields matter: reconciled_at is the state, reconciled_by_statement_id
    # is the evidence, and Entry#unmark_reconciled! clears the pair.
    on_first.reload
    assert_not on_first.reconciled?, "the account being left is released"
    assert_nil on_first.reconciled_by_statement_id, "its statement evidence is cleared too"

    on_other.reload
    assert on_other.reconciled?, "another account's evidence must survive"
    assert_equal @statement.id, on_other.reconciled_by_statement_id
  end

  test "reverting a fully reconciled import completes it rather than stranding it at pending" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :complete)
    assert_equal 0, @import.reload.rows_count

    @import.revert

    @import.reload
    assert_nil @import.error
    # pending with no rows renders the processing screen with no way back out.
    assert @import.complete?, "expected complete, got #{@import.status}"
    assert_equal 0, @import.rows_count
  end

  test "reverting an import puts the transactions it created back on offer" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert_equal 1, @import.reload.rows_count

    assert_difference -> { @account.entries.count }, 1 do
      @import.import!
    end
    @import.update!(status: :complete)

    assert_difference -> { @account.entries.count }, -1 do
      @import.revert
    end

    @import.reload
    assert @import.pending?, "expected pending, got #{@import.status}"
    assert_equal 1, @import.rows_count, "the created entry is gone, so its statement line is new again"
  end

  test "reverting releases evidence from an entry the statement no longer matches" do
    drifted = create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    assert drifted.reload.reconciled?
    @import.update!(status: :complete)

    # Corrected after the fact, so the statement line no longer describes it.
    drifted.update!(amount: 75)

    @import.revert

    drifted.reload
    assert_not drifted.reconciled?, "a statement that no longer matches must stop claiming the entry"
    assert_nil drifted.reconciled_by_statement_id
    assert_equal 1, @import.reload.rows_count
    assert @import.pending?, "expected pending, got #{@import.status}"
  end

  test "reassigning a published import is refused rather than half-unwinding it" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    @import.update!(status: :complete)

    other = @family.accounts.create!(
      name: "Wrong Turn Checking", balance: 0, currency: "USD", accountable: Depository.new
    )

    assert_not @import.assign_account!(other), "a replayed PATCH must not unwind a published import"

    @import.reload
    assert_equal @account, @import.account
    assert_equal 1, @import.rows_count, "the rows recording what was published survive"
    assert_equal 1, @import.entries.count
  end

  test "reassigning is refused while a job still owns the record" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.update!(status: :importing)

    other = @family.accounts.create!(
      name: "Mid Flight Checking", balance: 0, currency: "USD", accountable: Depository.new
    )

    assert_not @import.assign_account!(other)
    assert_equal @account, @import.reload.account
  end

  test "the outcome counts separate what was already recorded from what is new" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -12, name: "Bookstore")
    ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 2, @import.extracted_count
    assert_equal 1, @import.already_recorded_count
    assert_equal 0, @import.imported_count
    assert_equal 1, @import.awaiting_review_count
    assert @import.reconciled_anything?
  end

  test "publishing moves the offered rows into the imported count" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [
      extracted(date: @date, amount: -50, name: "Coffee"),
      extracted(date: @date, amount: -12, name: "Bookstore")
    ] })
    @import.generate_rows_from_extracted_data
    @import.import!
    @import.reload

    # Entries this import created are born reconciled too, so they must not be
    # counted as transactions the account already had.
    assert_equal 1, @import.already_recorded_count
    assert_equal 1, @import.imported_count
    # Rows survive publishing as the record of what was written, so the count
    # has to stop describing them as a queue.
    assert_equal 0, @import.awaiting_review_count
  end

  test "a fully reconciled statement reports everything as already recorded" do
    create_transaction(account: @account, date: @date, amount: 50, name: "Coffee")
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -50, name: "Coffee") ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 1, @import.extracted_count
    assert_equal 1, @import.already_recorded_count
    assert_equal 0, @import.imported_count
    assert_equal 0, @import.awaiting_review_count
  end

  test "an import that matched nothing reports nothing as already recorded" do
    @import.update!(extracted_data: { "transactions" => [ extracted(date: @date, amount: -12, name: "Bookstore") ] })
    @import.generate_rows_from_extracted_data
    @import.reload

    assert_equal 0, @import.already_recorded_count
    assert_not @import.reconciled_anything?
  end

  private

    def create_statement
      AccountStatement.create_from_upload!(
        family: @family,
        account: @account,
        file: uploaded_file(
          filename: "statement.pdf",
          content_type: "application/pdf",
          content: file_fixture("imports/sample_bank_statement.pdf").binread
        )
      )
    end
end
