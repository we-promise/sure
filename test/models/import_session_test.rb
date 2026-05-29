require "test_helper"

class ImportSessionTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "job requires import session" do
    error = assert_raises(ArgumentError) do
      ImportSessionJob.perform_now(nil)
    end

    assert_equal "ImportSessionJob requires an import_session", error.message
  end

  test "job publishes import session" do
    import_session = @family.import_sessions.create!
    import_session.expects(:publish).once

    ImportSessionJob.perform_now(import_session)
  end

  test "publishes ordered chunks with source mappings across files" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(
      sequence: 1,
      client_chunk_id: "entities",
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      client_chunk_id: "transactions",
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.complete?
    account = @family.accounts.find_by!(name: "Session Checking")
    entry = account.entries.find_by!(name: "Grocery Run")
    transaction = entry.entryable

    assert_equal "Groceries", transaction.category.name
    assert_equal "Market", transaction.merchant.name
    assert_equal [ "Weekly" ], transaction.tags.map(&:name)
    assert_equal "sure_import_session:#{session.id}", entry.source
    assert_equal "Transaction:txn-1", entry.external_id
    assert_equal 1, session.summary.dig("transactions", "created")

    assert_source_mapping session, "Account", "acct-1", account
    assert_source_mapping session, "Category", "cat-1", transaction.category
    assert_source_mapping session, "Merchant", "merchant-1", transaction.merchant
    assert_source_mapping session, "Tag", "tag-1", transaction.tags.first
    assert_source_mapping session, "Transaction", "txn-1", transaction
  end

  test "publishing session chunks records readback verification for each chunk" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    entity_chunk, transaction_chunk = session.imports.ordered_by_sequence.to_a
    assert_equal 1, entity_chunk.expected_record_counts["accounts"]
    assert_equal 1, transaction_chunk.expected_record_counts["transactions"]
    assert_includes SureImport::VERIFICATION_STATUSES, entity_chunk.readback_verification["status"]
    assert_equal 1, entity_chunk.readback_verification.dig("checked_counts", "accounts")
    assert_equal 1, transaction_chunk.readback_verification.dig("checked_counts", "transactions")
    assert_equal 1, transaction_chunk.readback_verification.dig("actual_delta_counts", "transactions")
  end

  test "publishing the same complete session does not duplicate imported transactions" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert_no_difference("Entry.count") do
      session.publish
    end
  end

  test "republishing failed session skips complete chunks and retries failed chunks" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )
    complete_chunk = session.imports.find_by!(sequence: 1)
    failed_chunk = session.imports.find_by!(sequence: 2)
    complete_chunk.update!(status: :complete, summary: { "accounts" => { "created" => 1 } }, error_details: {})
    failed_chunk.update!(status: :failed, error: "transient failure", error_details: { "code" => "import_failed" })
    session.update!(
      status: :failed,
      summary: complete_chunk.summary,
      error_details: { "code" => "import_failed", "message" => "transient failure" }
    )
    processed_sequences = []

    importer_factory = lambda do |_family, _content, import_session:, import:|
      processed_sequences << import.sequence
      flunk "completed chunk was reprocessed" if import.sequence == 1
      assert_equal session, import_session

      Object.new.tap do |importer|
        importer.define_singleton_method(:import!) do
          {
            accounts: [],
            entries: [],
            summary: { "transactions" => { "created" => 1 } }
          }
        end
      end
    end

    Family::DataImporter.stub(:new, importer_factory) do
      session.publish
    end

    assert_equal [ 2 ], processed_sequences
    assert complete_chunk.reload.complete?
    assert failed_chunk.reload.complete?
    assert session.reload.complete?
    assert_equal 1, session.summary.dig("accounts", "created")
    assert_equal 1, session.summary.dig("transactions", "created")
  end

  test "publish keeps session complete and records safe error when family sync enqueue fails" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    Family.any_instance.stubs(:sync_later).raises(StandardError, "redis://secret.local/0")
    session.publish

    assert session.reload.complete?
    assert_equal "family_sync_enqueue_failed", session.error_details["code"]
    assert_equal "Family sync could not be queued after import completion.", session.error_details["message"]
    assert_no_match(/secret/, session.error_details.to_json)
  end

  test "publish stores generic error details for unexpected import failures" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    importer_factory = ->(*) { raise StandardError, "redis://secret.local/0" }

    Family::DataImporter.stub(:new, importer_factory) do
      session.publish
    end

    assert session.reload.failed?
    assert_equal "Import session failed.", session.imports.first.error
    assert_equal "import_failed", session.error_details["code"]
    assert_equal "Import session failed.", session.error_details["message"]
    assert_no_match(/secret/, session.error_details.to_json)
  end

  test "publish later requires the exact expected chunk sequences" do
    session = @family.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    error = assert_raises(ImportSession::ConflictError) do
      session.publish_later
    end

    expected_message = "import session chunks do not match expected sequences " \
                       "(missing sequences: 2)"
    assert_equal expected_message, error.message
    assert session.reload.pending?
  end

  test "chunk upload rejects sequences beyond the expected chunk count" do
    session = @family.import_sessions.create!(expected_chunks: 1)

    error = assert_raises(ImportSession::ConflictError) do
      session.attach_chunk!(
        sequence: 2,
        content: build_ndjson(entity_records),
        filename: "entities.ndjson",
        content_type: "application/x-ndjson"
      )
    end

    assert_equal "sequence exceeds expected_chunks", error.message
    assert_empty session.imports
  end

  test "publish later restores status and records enqueue failures" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    ImportSessionJob.stub(:perform_later, ->(_import_session) { raise StandardError, "queue offline" }) do
      error = assert_raises(ImportSession::EnqueueError) do
        session.publish_later
      end

      assert_equal "Import session could not be queued.", error.message
    end

    assert session.reload.pending?
    assert_equal "import_enqueue_failed", session.error_details["code"]
    assert_equal "Import session could not be queued.", session.error_details["message"]
  end

  test "publish later syncs chunk row counts before enforcing row limit" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records + transaction_records),
      filename: "session.ndjson",
      content_type: "application/x-ndjson"
    )
    session.imports.update_all(rows_count: 0)

    SureImport.stub(:max_row_count, 1) do
      assert_raises(Import::MaxRowCountExceededError) { session.publish_later }
    end

    assert session.reload.pending?
    assert_equal 5, session.imports.reload.first.rows_count
  end

  test "fails loudly when a later chunk references a missing source id" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.failed?
    chunk = session.imports.first
    assert chunk.failed?
    assert_equal "missing_source_reference", chunk.error_details["code"]
    assert_equal "acct-1", chunk.error_details["source_id"]
    assert_equal 0, @family.entries.count
  end

  test "source mappings from another family cannot satisfy missing references" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_session = other_family.import_sessions.create!(expected_chunks: 1)
    other_session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(entity_records),
      filename: "other-entities.ndjson",
      content_type: "application/x-ndjson"
    )
    other_session.publish

    assert other_session.reload.complete?
    assert_equal 1, other_session.source_mappings.where(source_type: "Account", source_id: "acct-1").count

    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.failed?
    assert_equal "missing_source_reference", session.imports.first.error_details["code"]
    assert_equal "acct-1", session.imports.first.error_details["source_id"]
    assert_equal 0, @family.entries.count
  end

  test "session mode rejects invalid account accountable types" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson([
        {
          type: "Account",
          data: {
            id: "acct-invalid",
            name: "Invalid Account",
            balance: "100.00",
            currency: "USD",
            accountable_type: "Kernel"
          }
        }
      ]),
      filename: "accounts.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.failed?
    assert_equal 0, @family.accounts.count
    assert_equal "invalid_import_record", session.imports.first.error_details["code"]
    assert_equal "Account", session.imports.first.error_details["record_type"]
    assert_equal "accountable_type", session.imports.first.error_details["field"]
    assert_equal "Kernel", session.imports.first.error_details["value"]
  end

  test "chunk upload is idempotent by sequence and checksum" do
    session = @family.import_sessions.create!
    content = build_ndjson(entity_records)

    first = session.attach_chunk!(
      sequence: 1,
      content: content,
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    second = session.attach_chunk!(
      sequence: 1,
      content: content,
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    assert_equal first.id, second.id
    assert_raises(ImportSession::ConflictError) do
      session.attach_chunk!(
        sequence: 1,
        content: build_ndjson(transaction_records),
        filename: "different.ndjson",
        content_type: "application/x-ndjson"
      )
    end
  end

  test "chunk upload repairs incomplete existing chunk before accepting retry" do
    session = @family.import_sessions.create!
    content = build_ndjson(transaction_records)
    chunk = session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      client_chunk_id: "entities",
      checksum: Digest::SHA256.hexdigest(content)
    )

    result = session.attach_chunk!(
      sequence: 1,
      client_chunk_id: "entities",
      content: content,
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    assert_equal chunk.id, result.id
    assert result.reload.ndjson_file.attached?
    assert_equal 1, result.rows_count
  end

  test "chunk upload resyncs attached existing chunk before accepting retry" do
    session = @family.import_sessions.create!
    content = build_ndjson(transaction_records)
    chunk = session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      client_chunk_id: "entities",
      checksum: Digest::SHA256.hexdigest(content)
    )
    chunk.ndjson_file.attach(
      io: StringIO.new(content),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    result = session.attach_chunk!(
      sequence: 1,
      client_chunk_id: "entities",
      content: content,
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )

    assert_equal chunk.id, result.id
    assert_equal 1, result.rows_count
  end

  test "chunk upload rejects inconsistent sequence and client chunk keys" do
    session = @family.import_sessions.create!
    session.attach_chunk!(
      sequence: 1,
      client_chunk_id: "entities",
      content: build_ndjson(entity_records),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    session.attach_chunk!(
      sequence: 2,
      client_chunk_id: "transactions",
      content: build_ndjson(transaction_records),
      filename: "transactions.ndjson",
      content_type: "application/x-ndjson"
    )

    error = assert_raises(ImportSession::ConflictError) do
      session.attach_chunk!(
        sequence: 1,
        client_chunk_id: "transactions",
        content: build_ndjson(transaction_records),
        filename: "transactions.ndjson",
        content_type: "application/x-ndjson"
      )
    end

    assert_equal "sequence and client_chunk_id refer to different chunks", error.message
  end

  test "chunk upload treats duplicate insert races as idempotent retries" do
    session = @family.import_sessions.create!
    content = build_ndjson(entity_records)
    existing = session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      client_chunk_id: "entities",
      checksum: Digest::SHA256.hexdigest(content)
    )
    existing.ndjson_file.attach(
      io: StringIO.new(content),
      filename: "entities.ndjson",
      content_type: "application/x-ndjson"
    )
    existing.sync_ndjson_rows_count!
    lookup_count = 0

    session.stub(:existing_chunk_for!, ->(**) {
      lookup_count += 1
      lookup_count == 1 ? nil : existing
    }) do
      session.stub(:create_chunk!, ->(**) { raise ActiveRecord::RecordNotUnique, "duplicate chunk" }) do
        assert_equal existing, session.attach_chunk!(
          sequence: 1,
          client_chunk_id: "entities",
          content: content,
          filename: "entities.ndjson",
          content_type: "application/x-ndjson"
        )
      end
    end

    assert_equal 2, lookup_count
  end

  test "client session creation treats duplicate insert races as idempotent retries" do
    existing = @family.import_sessions.create!(client_session_id: "race-session", expected_chunks: 2)
    ImportSession.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

    session = ImportSession.create_or_find_for!(
      family: @family,
      import_type: "SureImport",
      client_session_id: "race-session",
      expected_chunks: 2
    )

    assert_equal existing, session
  end

  test "client session creation race backfills missing expected chunks" do
    existing = @family.import_sessions.create!(client_session_id: "race-session")
    racing_session = @family.import_sessions.build(client_session_id: "race-session")
    racing_session.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

    @family.import_sessions.stub(:find_or_initialize_by, racing_session) do
      session = ImportSession.create_or_find_for!(
        family: @family,
        import_type: "SureImport",
        client_session_id: "race-session",
        expected_chunks: 2
      )

      assert_equal existing, session
    end
    assert_equal 2, existing.reload.expected_chunks
  end

  test "client session creation race preserves expected chunks conflict" do
    @family.import_sessions.create!(client_session_id: "race-session", expected_chunks: 2)
    ImportSession.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique)

    error = assert_raises(ImportSession::ConflictError) do
      ImportSession.create_or_find_for!(
        family: @family,
        import_type: "SureImport",
        client_session_id: "race-session",
        expected_chunks: 3
      )
    end

    assert_equal "client_session_id already exists with a different expected_chunks value", error.message
  end

  test "session mode rejects rule records without source ids" do
    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: build_ndjson([
        {
          type: "Rule",
          data: {
            name: "Missing Source Rule",
            resource_type: "transaction",
            active: true
          }
        }
      ]),
      filename: "rules.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.failed?
    assert_equal 0, @family.rules.count
    assert_equal "missing_source_reference", session.imports.first.error_details["code"]
    assert_equal "Rule", session.imports.first.error_details["record_type"]
    assert_equal "(blank)", session.imports.first.error_details["source_id"]
  end

  test "session mode imports rule records exported by Sure packages" do
    source_family = Family.create!(name: "Rule Export Source", currency: "USD", locale: "en")
    category = source_family.categories.create!(
      name: "Exported Category",
      color: "#00AA00",
      lucide_icon: "shapes"
    )
    source_rule = source_family.rules.build(
      name: "Exported Rule",
      resource_type: "transaction",
      active: true
    )
    source_rule.conditions.build(
      condition_type: "transaction_name",
      operator: "like",
      value: "Coffee"
    )
    source_rule.actions.build(
      action_type: "set_transaction_category",
      value: category.id
    )
    source_rule.save!

    session = @family.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: exported_ndjson_for(source_family),
      filename: "all.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.complete?
    imported_rule = @family.rules.find_by!(name: "Exported Rule")
    imported_category = @family.categories.find_by!(name: "Exported Category")

    assert_equal 1, session.summary.dig("rules", "created")
    assert_equal imported_category.id, imported_rule.actions.first.value
    assert_source_mapping session, "Rule", source_rule.id, imported_rule
  end

  test "client idempotency keys are bounded before indexed writes" do
    session = @family.import_sessions.build(client_session_id: "x" * 256)

    assert_not session.valid?
    assert_includes session.errors[:client_session_id], "is too long (maximum is 255 characters)"

    import = @family.imports.build(type: "SureImport", client_chunk_id: "x" * 256)

    assert_not import.valid?
    assert_includes import.errors[:client_chunk_id], "is too long (maximum is 255 characters)"

    import.sequence = 0
    import.checksum = "short"

    assert_not import.valid?
    assert_includes import.errors[:sequence], "must be greater than 0"
    assert_includes import.errors[:checksum], "is the wrong length (should be 64 characters)"

    other_family = Family.create!(name: "Other Import Family", currency: "USD", locale: "en")
    import.import_session = other_family.import_sessions.build
    import.sequence = nil
    import.checksum = nil

    assert_not import.valid?
    assert_includes import.errors[:import_session], "must belong to your family"
    assert_includes import.errors[:sequence], "must be present for import session chunks"
    assert_includes import.errors[:checksum], "must be present for import session chunks"

    mapping = @family.import_source_mappings.build(
      import_session: @family.import_sessions.build,
      source_type: "x" * 65,
      source_id: "x" * 256,
      target_type: "Account",
      target_id: SecureRandom.uuid
    )

    assert_not mapping.valid?
    assert_includes mapping.errors[:source_type], "is too long (maximum is 64 characters)"
    assert_includes mapping.errors[:source_id], "is too long (maximum is 255 characters)"

    mapping.source_type = "Unsupported"
    mapping.source_id = "acct-1"

    assert_not mapping.valid?
    assert_includes mapping.errors[:source_type], "is not included in the list"

    mapping.source_type = "Account"
    mapping.target_type = "Unsupported"

    assert_not mapping.valid?
    assert_includes mapping.errors[:target_type], "is not included in the list"
  end

  test "client idempotency keys are stripped before validation" do
    session = @family.import_sessions.create!(client_session_id: "  session-1  ")
    import = @family.imports.create!(type: "SureImport", client_chunk_id: "  chunk-1  ")
    category = @family.categories.create!(name: "Mapping Category")
    mapping = session.source_mappings.create!(
      family: @family,
      source_type: "Category",
      source_id: "  cat-1  ",
      target: category
    )

    assert_equal "session-1", session.client_session_id
    assert_equal "chunk-1", import.client_chunk_id
    assert_equal "cat-1", mapping.source_id
  end

  test "session status payloads must remain JSON objects" do
    session = @family.import_sessions.build(summary: [], error_details: "failed")
    import = @family.imports.build(type: "SureImport", summary: [], error_details: "failed")

    assert_not session.valid?
    assert_includes session.errors[:summary], "must be an object"
    assert_includes session.errors[:error_details], "must be an object"

    assert_not import.valid?
    assert_includes import.errors[:summary], "must be an object"
    assert_includes import.errors[:error_details], "must be an object"
  end

  test "source mappings must belong to the same family as their import session" do
    other_family = Family.create!(name: "Other Mapping Family", currency: "USD", locale: "en")
    mapping = other_family.import_source_mappings.build(
      import_session: @family.import_sessions.build,
      source_type: "Account",
      source_id: "acct-1",
      target: @family.accounts.build(name: "Session Checking")
    )

    assert_not mapping.valid?
    assert_includes mapping.errors[:family], "must match import session"
  end

  test "source mapping targets must not cross family boundaries" do
    other_family = Family.create!(name: "Other Mapping Target Family", currency: "USD", locale: "en")
    mapping = @family.import_source_mappings.build(
      import_session: @family.import_sessions.build,
      source_type: " Account ",
      source_id: "acct-1",
      target: other_family.accounts.build(name: "Other Checking")
    )

    assert_not mapping.valid?
    assert_equal "Account", mapping.source_type
    assert_includes mapping.errors[:target], "must belong to your family"
  end

  private
    def entity_records
      [
        {
          type: "Account",
          data: {
            id: "acct-1",
            name: "Session Checking",
            balance: "100.00",
            currency: "USD",
            accountable_type: "Depository",
            accountable: { subtype: "checking" }
          }
        },
        {
          type: "Category",
          data: {
            id: "cat-1",
            name: "Groceries",
            color: "#407706",
            classification: "expense"
          }
        },
        {
          type: "Merchant",
          data: {
            id: "merchant-1",
            name: "Market",
            color: "#111111"
          }
        },
        {
          type: "Tag",
          data: {
            id: "tag-1",
            name: "Weekly",
            color: "#222222"
          }
        }
      ]
    end

    def transaction_records
      [
        {
          type: "Transaction",
          data: {
            id: "txn-1",
            account_id: "acct-1",
            category_id: "cat-1",
            merchant_id: "merchant-1",
            tag_ids: [ "tag-1" ],
            date: "2024-01-15",
            amount: "-12.34",
            currency: "USD",
            name: "Grocery Run"
          }
        }
      ]
    end

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end

    def exported_ndjson_for(family)
      ndjson = nil

      Zip::File.open_buffer(Family::DataExporter.new(family).generate_export) do |zip|
        ndjson = zip.read("all.ndjson")
      end

      ndjson
    end

    def assert_source_mapping(session, source_type, source_id, target)
      mapping = session.source_mappings.find_by!(source_type: source_type, source_id: source_id)

      assert_equal @family, mapping.family
      assert_equal target, mapping.target
    end
end
