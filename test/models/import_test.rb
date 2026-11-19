require "test_helper"

class ImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "publish_later checks the publisher and records them" do
    import = imports(:transaction)
    import.update!(account: accounts(:credit_card))
    import.stubs(:publishable?).returns(true)

    error = assert_raises(Import::PublishNotAllowedError) { import.publish_later(user: users(:family_member)) }
    assert_equal :accounts, error.reason
    assert import.reload.pending?

    import.update!(account: accounts(:depository))
    import.publish_later(user: users(:family_member))
    assert import.reload.importing?
    assert_equal users(:family_member), import.published_by
  end

  test "publish_later refuses an import that is already published" do
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)

    assert_enqueued_jobs(1, only: ImportJob) do
      import.publish_later(user: users(:family_admin))
      assert_raises(Import::AlreadyPublishedError) { Import.find(import.id).publish_later(user: users(:family_admin)) }
    end

    import.update!(status: :complete)
    assert_raises(Import::AlreadyPublishedError) { import.publish_later(user: users(:family_admin)) }
  end

  test "the publish lock refuses to run inside a caller's transaction" do
    import = imports(:transaction)

    Import.transaction do
      assert_raises(Import::PublishLockInTransaction) { import.with_publish_lock { flunk "ran inside a transaction" } }
    end
  end

  test "a failed enqueue puts the import back as it was in the database" do
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)
    # This copy still reads importing; another one has since failed it.
    import.update!(status: :importing)
    Import.find(import.id).update!(status: :failed)
    ImportJob.stubs(:perform_later).raises(StandardError, "queue down")

    error = assert_raises(StandardError) { import.publish_later(user: users(:family_admin)) }
    assert_equal "queue down", error.message

    import.reload
    assert import.failed?
    assert_nil import.published_by
  end

  test "a guest can't publish an import that would create categories or tags" do
    guest = family_guest
    import = imports(:transaction)
    import.stubs(:publishable?).returns(true)
    import.stubs(:creates_categories_or_tags?).returns(true)

    error = assert_raises(Import::PublishNotAllowedError) { import.publish_later(user: guest) }
    assert_equal :guest_categories_or_tags, error.reason
  end

  test "the publish lock is released when setting it up fails after taking it" do
    import = imports(:transaction)
    import.stubs(:backend_pid).raises(ActiveRecord::QueryCanceled, "canceled")

    assert_raises(ActiveRecord::QueryCanceled) { import.with_publish_lock { flunk "ran without a lock session" } }

    held = Import.connection.select_value(Import.sanitize_sql_array([ <<~SQL.squish, Import::PUBLISH_LOCK_NAMESPACE, import.id.to_s ]))
      SELECT count(*) FROM pg_locks
      WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted AND objsubid = 2
        AND classid = ? AND objid::bigint = (hashtext(?)::bigint & 4294967295)
    SQL
    assert_equal 0, held
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
