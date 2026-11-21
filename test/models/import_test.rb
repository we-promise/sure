require "test_helper"

class ImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "publish_later releases the claim when enqueueing raises" do
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)
    ImportJob.stubs(:perform_later).raises(StandardError, "queue down")

    assert_raises(Import::EnqueueFailedError) { import.publish_later }

    assert import.reload.pending?, "the failed enqueue must not block a retry"
  end

  test "publish_later releases the claim when enqueueing returns nothing" do
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)
    ImportJob.stubs(:perform_later).returns(nil)

    assert_raises(Import::EnqueueFailedError) { import.publish_later }

    assert import.reload.pending?
  end

  test "publish_later invalidates a reread claim when it takes the publish claim" do
    import = imports(:pdf_with_rows)
    import.update!(status: :pending, reread_token: "old-attempt")
    import.stubs(:publishable?).returns(true)

    assert_enqueued_with(job: ImportJob) { import.publish_later }

    import.reload
    assert import.importing?
    assert_not_equal "old-attempt", import.reread_token, "a delayed reread must not find its claim on a published import"
  end

  test "publish_later does not release a newer claim when an older enqueue fails" do
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)
    newer_token = SecureRandom.uuid
    ImportJob.stubs(:perform_later)
              .with { import.reload.update!(status: :importing, reread_token: newer_token); true }
              .raises(StandardError, "queue down")

    assert_raises(Import::EnqueueFailedError) { import.publish_later }

    import.reload
    assert import.importing?
    assert_equal newer_token, import.reread_token
  end

  test "publish_later refuses an import already reverting" do
    import = imports(:transaction)
    import.update!(status: :reverting)
    import.stubs(:publishable?).returns(true)

    assert_raises(Import::AlreadyClaimedError) { import.publish_later }
    assert import.reload.reverting?, "a second claim must not take over a revert in flight"
  end

  test "publish skips imports in terminal statuses" do
    import = imports(:transaction)
    import.update_columns(status: "complete")

    import.expects(:import!).never

    import.publish

    assert_equal "complete", import.reload.status
  end

  test "publish schedules the catch-up sync for scheduled entries it created" do
    import = imports(:transaction)
    account = accounts(:depository)
    import.define_singleton_method(:import!) do
      account.entries.create!(
        name: "Upcoming bill", date: 3.days.from_now.to_date, amount: 100, currency: "USD",
        entryable: Transaction.new, import: self
      )
    end

    assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
      import.publish
    end

    assert_equal "complete", import.reload.status
  end

  test "publish skips imports that are reverting" do
    import = imports(:transaction)
    import.update_columns(status: "reverting")

    import.expects(:import!).never

    import.publish

    assert_equal "reverting", import.reload.status
  end

  test "publish_later enqueues the publish with its claim token" do
    import = imports(:pdf_with_rows)
    import.update!(status: :pending, reread_token: "old-attempt")
    import.stubs(:publishable?).returns(true)

    assert_enqueued_with(job: ImportJob) { import.publish_later }

    token = import.reload.reread_token
    assert_equal token, enqueued_jobs.last[:args].last.with_indifferent_access[:publish_token]
  end

  test "publish with a stale token leaves a newer reread claim intact" do
    import = imports(:pdf_with_rows)
    import.update_columns(status: "importing", reread_token: "current")
    import.expects(:import!).never

    import.publish(publish_token: "stale")

    import.reload
    assert import.importing?
    assert_equal "current", import.reread_token
  end

  test "publish with the current token consumes the claim before importing" do
    import = imports(:transaction)
    import.update_columns(status: "importing", reread_token: "current")
    import.stubs(:import!)

    import.publish(publish_token: "current")

    assert import.reload.complete?
    assert_nil import.reread_token
  end

  test "publish_later refuses blank row dates with a correction message" do
    import = imports(:transaction)
    import.update_columns(status: "pending", reread_token: nil)
    import.rows.first.update_columns(date: "")
    import.stubs(:publishable?).returns(true)

    assert_no_enqueued_jobs do
      error = assert_raises(Import::InvalidRowDataError) { import.publish_later }
      assert_equal I18n.t("imports.errors.blank_dates"), error.message
    end

    assert import.reload.pending?
    assert_nil import.reread_token
  end

  test "publish refuses blank row dates before importing" do
    import = imports(:transaction)
    import.update_columns(status: "pending", reread_token: nil)
    import.rows.first.update_columns(date: "")
    import.expects(:import!).never

    import.publish

    assert import.reload.failed?
    assert_equal I18n.t("imports.errors.blank_dates"), import.error
  end

  test "a blank row date is reported as a row data error" do
    import = imports(:transaction)
    row = import.rows.first
    row.update_columns(date: "")

    error = assert_raises(Import::InvalidRowDataError) { row.date_iso }

    assert_equal I18n.t("imports.errors.blank_dates"), error.message
  end

  test "clean fails stuck imports but leaves PdfImports to their own reclaim" do
    stuck_csv = imports(:transaction)
    stuck_csv.update_columns(status: "importing", updated_at: 7.hours.ago)

    stuck_pdf = imports(:pdf)
    stuck_pdf.update_columns(status: "importing", updated_at: 7.hours.ago)

    Import.clean

    assert_equal "failed", stuck_csv.reload.status
    assert_equal "importing", stuck_pdf.reload.status
  end

  test "clean leaves session-owned chunks to ImportSession.clean" do
    family = families(:dylan_family)
    session = family.import_sessions.create!(status: "importing")
    chunk = TransactionImport.create!(
      family: family,
      import_session: session,
      sequence: 1,
      checksum: Digest::SHA256.hexdigest("chunk"),
      status: "importing"
    )
    chunk.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "importing", chunk.reload.status
  end

  test "clean completes a stuck import whose data already committed" do
    stuck = imports(:transaction)
    stuck.update_columns(status: "importing", updated_at: 7.hours.ago)
    entries(:transaction).update_columns(import_id: stuck.id)

    Import.clean

    stuck.reload
    assert_equal "complete", stuck.status
    assert_nil stuck.error
  end

  test "clean moves a stuck revert to revert_failed" do
    stuck = imports(:transaction)
    stuck.update_columns(status: "reverting", updated_at: 7.hours.ago)

    Import.clean

    assert_equal "revert_failed", stuck.reload.status
  end

  test "PdfImport clean reclaims the AI claim but completes a committed publish" do
    ai_claim = imports(:pdf)
    ai_claim.update_columns(status: "importing", updated_at: 7.hours.ago)

    published = imports(:pdf_processed)
    published.update_columns(status: "importing", updated_at: 7.hours.ago)
    entries(:transaction).update_columns(import_id: published.id)

    PdfImport.clean

    assert_equal "pending", ai_claim.reload.status
    assert_equal "complete", published.reload.status
  end

  test "PdfImport clean moves a stuck revert to revert_failed" do
    stuck = imports(:pdf)
    stuck.update_columns(status: "reverting", updated_at: 7.hours.ago)

    PdfImport.clean

    assert_equal "revert_failed", stuck.reload.status
  end

  test "force_fail! refuses records that have not been idle long enough" do
    import = imports(:transaction)
    import.update_columns(status: "importing", updated_at: 5.minutes.ago)

    assert_not import.force_fail!
    assert_equal "importing", import.reload.status
  end

  test "force_fail! fails a lost import and keeps reverts retryable" do
    lost_import = imports(:transaction)
    lost_import.update_columns(status: "importing", updated_at: 2.hours.ago)

    assert lost_import.force_fail!
    assert_equal "failed", lost_import.reload.status
    assert_equal Import.lost_error_message, lost_import.error

    lost_revert = imports(:trade)
    lost_revert.update_columns(status: "reverting", updated_at: 2.hours.ago)

    assert lost_revert.force_fail!
    assert_equal "revert_failed", lost_revert.reload.status
  end

  test "force_fail! refuses terminal statuses" do
    import = imports(:transaction)
    import.update_columns(status: "complete", updated_at: 2.hours.ago)

    assert_not import.force_fail!
    assert_equal "complete", import.reload.status
  end

  test "force_fail! releases a lost PdfImport claim back to pending" do
    pdf = imports(:pdf)
    pdf.update_columns(status: "importing", updated_at: 2.hours.ago)

    assert pdf.force_fail!
    assert_equal "pending", pdf.reload.status
  end

  # Category/Merchant/Rule imports attach nothing to the import (their records
  # hang off the family), so reap_stuck! leans on the type-specific
  # data_committed? override to tell a committed run from a rolled-back one.
  test "clean completes a stuck CategoryImport whose categories committed" do
    family = families(:dylan_family)
    stuck = CategoryImport.create!(family: family, status: "importing")
    stuck.rows.create!(source_row_number: 1, name: categories(:income).name, currency: "USD")
    stuck.update_columns(updated_at: 7.hours.ago)

    Import.clean

    stuck.reload
    assert_equal "complete", stuck.status
    assert_nil stuck.error
  end

  test "clean fails a stuck CategoryImport whose categories never committed" do
    family = families(:dylan_family)
    stuck = CategoryImport.create!(family: family, status: "importing")
    stuck.rows.create!(source_row_number: 1, name: "Never Committed Category", currency: "USD")
    stuck.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "failed", stuck.reload.status
  end

  test "clean completes a stuck MerchantImport whose merchants committed" do
    family = families(:dylan_family)
    stuck = MerchantImport.create!(family: family, status: "importing")
    stuck.rows.create!(source_row_number: 1, name: merchants(:netflix).name, currency: "USD")
    stuck.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "complete", stuck.reload.status
  end

  test "clean completes a stuck RuleImport whose named rules committed" do
    family = families(:dylan_family)
    # Skip Rule's own validations — the reaper only asks whether a rule with
    # this name exists in the family, which is the state a committed import
    # leaves behind.
    family.rules.new(resource_type: "transaction", name: "Committed rule").save!(validate: false)
    stuck = RuleImport.create!(family: family, status: "importing")
    stuck.rows.create!(source_row_number: 1, name: "Committed rule", resource_type: "transaction", conditions: "[]", actions: "[]", currency: "USD")
    stuck.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "complete", stuck.reload.status
  end

  test "clean fails a stuck RuleImport of only nameless rows (no commit signal)" do
    family = families(:dylan_family)
    stuck = RuleImport.create!(family: family, status: "importing")
    stuck.rows.create!(source_row_number: 1, name: "", resource_type: "transaction", conditions: "[]", actions: "[]", currency: "USD")
    stuck.update_columns(updated_at: 7.hours.ago)

    Import.clean

    assert_equal "failed", stuck.reload.status
  end

  test "CSV-only date formats are not offered as a global family preference" do
    # 2-digit years are ambiguous (see we-promise/sure#1530 and the rejected
    # PR #531), so this format must stay out of Family::DATE_FORMATS and only
    # be offered on the CSV mapping screen, where the user can preview it
    # against their own data.
    assert_empty Import::CSV_ONLY_DATE_FORMATS & Family::DATE_FORMATS
  end

  test "date_format accepts a CSV-only format like DD/MM/YY" do
    import = imports(:transaction)
    import.update!(date_format: "%d/%m/%y")

    assert_equal Date.new(2024, 5, 15), Date.strptime("15/05/24", import.date_format)
  end

  test "parse_csv_str keeps a quote that is part of the value" do
    csv = Import.parse_csv_str("name\nO'Brien\n")

    assert_equal "O'Brien", csv.first["name"]
  end

  test "parse_csv_str preserves a literal leading apostrophe before a formula marker" do
    csv = Import.parse_csv_str("name\n'+44 Taxis\n+44 Taxis\n")

    assert_equal [ "'+44 Taxis", "+44 Taxis" ], csv["name"]
  end
end
