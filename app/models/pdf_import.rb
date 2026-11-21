class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  # "Read as", per upload: Auto, or one way of reading the PDF.
  READ_AS = Ai::PdfReading::READ_AS.map(&:to_s).freeze
  # Reconciliation dependencies ride in extracted_data: a statement's own reading, not a new
  # schema, owns the list of existing entries it decided were already recorded. A later import
  # on the same statement can claim the same entry, so clearing one reading must hand that mark
  # back to another reading that still needs it.
  RECONCILED_IDS_KEY = "_reconciled_entry_ids".freeze
  # What ReadPdf says the document is.
  Analysis = Data.define(:summary, :document_type, :extracted_data)

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validates :read_as, inclusion: { in: READ_AS }, allow_nil: true
  validate :account_statement_matches_import

  class << self
    # PdfImport's importing status doubles as a processing claim: the AI
    # extraction claim from process_with_ai_later (no rows yet) or a regular
    # publish (rows being written). A lost job leaves the claim held forever —
    # ProcessPdfJob's own reclaim only runs when the job is redelivered.
    # Which claim died is observable from the data: no rows attached → the AI
    # claim, reclaim to pending so the user can re-trigger; rows attached →
    # the publish died after import!'s commit, so finalize as complete
    # (pending would let the user publish the same extracted rows again —
    # PdfImport#import! always builds new transactions). Stuck reverts go to
    # revert_failed like every other import, keeping the retry path exposed.
    def clean
      where(status: [ :importing, :reverting ])
        .where("updated_at < ?", Import::STUCK_AFTER.ago)
        .includes(:family)
        .find_each do |pdf_import|
          reap_stuck!(pdf_import)
        rescue => e
          # One bad record must not abort the sweep for the rest.
          Rails.logger.error("PdfImport.clean failed for #{pdf_import.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) { |scope| scope.set_tags(record_type: name, record_id: pdf_import.id) } if defined?(Sentry)
        end
    end

    def reap_stuck!(pdf_import)
      needs_sync = false
      # Read before the lock — see Import.reap_stuck!.
      family = pdf_import.family

      pdf_import.with_lock do
        next unless pdf_import.reapable_since?(Import::STUCK_AFTER.ago)

        previous_status = pdf_import.status
        if previous_status == "reverting"
          pdf_import.update!(status: :revert_failed, error: Import.interrupted_error_message, reread_token: nil)
        else
          needs_sync = pdf_import.recover_lost_claim!
        end

        DebugLogEntry.capture(
          category: "background_jobs",
          level: "warn",
          message: "Reclaimed PdfImport stuck in #{previous_status} for over #{Import::STUCK_AFTER.inspect} (→ #{pdf_import.status})",
          source: name,
          family: family,
          metadata: { record_type: name, record_id: pdf_import.id, previous_status: previous_status, new_status: pdf_import.status }
        )
      end

      # Outside the row lock — see Import.reap_stuck!.
      family.sync_later if needs_sync
    end

    def create_from_upload!(family:, file:, user:, read_as: nil)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: AccountStatement.prepare_upload!(file)
      )

      create_from_statement!(statement: statement, read_as:)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement, read_as:)
    end

    def create_from_statement!(statement:, read_as: nil)
      read_as = read_as.presence_in(PdfImport::READ_AS)
      reusable_import = statement.latest_reusable_pdf_import
      if reusable_import && reusable_import.account_id == statement.account_id &&
         reusable_import.date_format == statement.family.date_format
        # Under its lock, and only while unclaimed: a job already reading it keeps its way.
        reusable_import.with_lock { reusable_import.update!(read_as:) if reusable_import.pending? && !reusable_import.ai_processed? } if read_as
        return reusable_import
      end

      create!(family: statement.family, account: statement.account, account_statement: statement, date_format: statement.family.date_format,
              status: :pending, read_as:)
    end

    # Where Auto starts: the way the last extraction for this account and model that passed, or
    # that had nothing another way could fix (a statement without balances), used.
    # Keyed by the model Auto started from (`tuned_model`), not the one that answered: when a
    # fallback answered, the next upload still starts from the same primary. Readings from before
    # the key was stored fall back to their answering model.
    def last_passing_way(account:, model:)
      return if account.nil? || model.blank?

      where(account:).where.not(read_with: nil)
        .where("extraction_checks ->> 'tuned_model' = :model OR (extraction_checks ->> 'tuned_model' IS NULL AND read_model = :model)",
               model:)
        .where("extraction_checks ->> 'passed' = 'true' OR extraction_checks ->> 'settled' = 'true'")
        .order(updated_at: :desc).pick(:read_with)
    end

    # Why no model could read a PDF, from Ai::Error::Unavailable's reason.
    def unavailable_message(reason)
      I18n.t("imports.pdf_import.errors.unavailable.#{reason}", default: I18n.t("imports.pdf_import.errors.unavailable.default"))
    end
  end

  # A PdfImport's importing status is a processing claim (AI extraction or
  # publish). Release a lost claim (release_lost_claim!) so the user can re-trigger
  # processing, mirroring ProcessPdfJob's own reclaim; lost reverts keep the
  # base revert_failed behavior.
  def force_fail!(error_message = Import.lost_error_message)
    return super if reverting?

    needs_sync = with_lock do
      return false unless presumed_lost?

      recover_lost_claim!(error_message)
    end
    family.sync_later if needs_sync

    true
  end

  # Under the row lock. A publish whose ledger transaction committed finishes as complete (true:
  # the family needs a sync); publishing again would insert its rows twice. Otherwise the claim
  # is released.
  def recover_lost_claim!(error_message = Import.lost_error_message)
    if data_committed?
      update!(status: :complete, error: nil, reread_token: nil)
    else
      release_lost_claim!(error_message)
      false
    end
  end

  # A lost claim goes back to pending so the user can start it again, except a reading that had
  # already written something (a reread that cleared the previous reading, or an initial reading
  # that classified the document): pending with no rows shows "processing" with nothing to press,
  # so it fails instead, which offers "Read again".
  def release_lost_claim!(error_message = Import.lost_error_message)
    if rows_count.zero? && (reread_token.present? || ai_processed?)
      update!(status: :failed, error: error_message, reread_token: nil)
    else
      update!(status: :pending, reread_token: nil)
    end
  end

  def import!
    raise "Account required for PDF import" unless account.present?

    transaction do
      mappings.each(&:create_mappable!)

      # Rows were already filtered against existing records when they were
      # generated, but a provider sync can land in between, so check again here
      # the way TransactionImport#import! does.
      adapter = Account::ProviderImportAdapter.new(account)
      # Entries this statement already consumed during row generation are spoken
      # for. Without excluding them, a statement carrying two same-amount
      # transactions where the account held only one would re-match the surviving
      # row against that same entry and silently drop a genuinely new
      # transaction. Newly synced entries are still caught, because only the
      # already-reconciled ones are excluded.
      claimed = reconciled_entries.pluck(:id)
      reconciled_now = []
      reconciled_at = Time.current

      new_transactions = rows.filter_map do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          reconciled_now << existing
          next
        end

        Transaction.new(
          category: mappings.categories.mappable_for(row.category),
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self,
            import_locked: true,
            # Born reconciled: the statement being imported is the evidence.
            # Set by id rather than association so activerecord-import writes the
            # column directly on the recursive insert.
            reconciled_at: reconciled_at,
            reconciled_by_statement_id: account_statement&.id,
            reconciled_by_import_id: id
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
      reconcile_entries!(reconciled_now, at: reconciled_at)
    end
  end

  # Re-targeting is destructive: it releases the statement's evidence on the
  # account being left and rebuilds the rows from scratch. Returns false rather
  # than doing any of that when the import is no longer re-targetable, so a
  # back-button or replayed PATCH cannot unwind a published import.
  def assign_account!(account)
    with_lock do
      return false unless reassignable?

      previous_account_id = account_id
      update!(account: account)

      if (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
      end

      next true if previous_account_id == account.id

      # Matching is per-account, so anything reconciled against the old account
      # is no longer evidence-backed, and the rows have to be judged again.
      release_reconciliations!(previous_account_id)
      if has_extracted_transactions?
        generate_rows_from_extracted_data
        sync_mappings
        refresh_status_after_regeneration!
      end

      true
    end
  end

  # A published import's entries already live in the account it was published
  # to, and a running job owns the record while it is importing or reverting.
  # An import that reconciled every line is still re-targetable: it is complete
  # but committed nothing of its own, and the user may well have picked the
  # wrong account.
  def reassignable?
    !data_committed? && !importing? && !reverting?
  end

  def pdf_uploaded?
    statement_backed? || pdf_file.attached?
  end

  # ReadPdf has answered: every reading stores a document type, and the summary is optional prose.
  def ai_processed?
    document_type.present?
  end

  def process_with_ai_later
    # Clearing the token is part of taking the claim: a reread job delayed in
    # the queue must not find its old attempt still owning this processing run.
    return false unless with_lock { pending? && !ai_processed? && rows_count.zero? && pdf_uploaded? && update!(status: :importing, reread_token: nil) }

    queued = begin
      ProcessPdfJob.perform_later(self)
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF processing for import #{id}: #{e.class.name}")
      false
    end
    return true if queued

    # perform_later can also return false without raising. A reread that claimed the import in the
    # meantime holds a token, and its claim isn't this attempt's to release.
    with_lock { update!(status: :pending) if importing? && reread_token.nil? }
    false
  end

  # What the document is (Ai::Generations::ReadPdf), read the way the upload asked for.
  def process_with_ai(reread_token: nil)
    outcome = pdf_reading.read(read_as: requested_way)
    analysis = Analysis.new(summary: outcome.value[:summary], document_type: outcome.value[:document_type] || "other",
                            extracted_data: outcome.value[:extracted_data])
    return unless with_claim(reread_token) { update!(ai_summary: analysis.summary, document_type: analysis.document_type) }
    return unless with_claim(reread_token) { sync_statement_metadata_from_process_result(analysis); true }

    analysis
  end

  # The statement's rows (Ai::Generations::ExtractBankStatement), read the way the upload asked
  # for, or by Auto starting from the way that last passed for this account and model. A failing
  # extraction is kept and flagged for review, never dropped.
  def extract_transactions(reread_token: nil)
    return unless statement_with_transactions?

    reading = pdf_reading
    outcome = reading.extract(read_as: requested_way, start: self.class.last_passing_way(account:, model: reading.model&.name))
    # String keys: every reader here digs with strings, and jsonb keeps the hash as assigned
    # until the record is reloaded.
    data = Ai::Generations::ExtractBankStatement.statement(outcome.value).deep_stringify_keys
    return unless with_claim(reread_token) do
      update!(extracted_data: data, read_with: outcome.way.to_s, read_model: outcome.model,
              extraction_checks: (outcome.checks&.to_h || {}).merge(attempts: outcome.attempts, tuned_model: reading.model&.name)
                                                             .deep_stringify_keys)
    end
    return unless with_claim(reread_token) { sync_statement_metadata_from_extracted_data(data); true }

    data
  end

  # The checks a kept extraction failed, for the review flag.
  def failed_checks
    return [] unless extraction_flagged?

    Ai::Generations::ExtractBankStatement::Checks.from_h(extraction_checks).failed.map(&:to_s)
  end

  def extraction_flagged? = extraction_checks.present? && extraction_checks["passed"] == false

  # "Read again as…" is offered before anything is published: while the rows wait for review,
  # after a failure, or when a flagged reading finished without rows.
  def rereadable?
    !entries.exists? && (pending? || failed? || (complete? && extraction_flagged?))
  end

  # "Read again as…": a badly read statement, read another way without changing the config. The
  # import is claimed under its row lock with an attempt-specific token, as publishing claims it,
  # and the previous reading stays until ProcessPdfJob starts (#clear_reading!), so a job that
  # can't be queued loses nothing.
  def reread!(read_as)
    read_as = read_as.to_s
    raise ArgumentError, "unknown way #{read_as}" unless READ_AS.include?(read_as)
    return false unless pdf_uploaded?
    begin
      return false if read_as != "auto" && !pdf_reading.usable?(read_as)   # this file can't be read that way
    rescue Ai::Error::Unavailable   # the last route was removed after the form was shown
      return false
    end

    previous = nil
    token = with_lock do
      next false unless rereadable?

      previous = { status:, read_as: self.read_as }
      attempt = SecureRandom.uuid
      update!(read_as:, status: :importing, reread_token: attempt)
      attempt
    end
    return false unless token

    queued = begin
      ProcessPdfJob.perform_later(self, reread: true, reread_token: token)
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF reread for import #{id}: #{e.class.name}")
      false
    end
    return true if queued

    # Restore only while this attempt still owns the claim. A job that has
    # started reading owns the import now; its way must not change underneath it.
    with_lock do
      update!(status: previous[:status], read_as: previous[:read_as], reread_token: nil) if importing? && reread_token == token
    end
    :enqueue_failed
  end

  # Runs a write only while this attempt still owns the import. A long OCR read can outlive the
  # claim's recovery window; once another reread takes over, the stale job must leave the new
  # attempt's data and token alone. A blank token is a direct read/publish on an unclaimed import.
  def with_claim(token)
    with_lock do
      next false if token.blank? && reread_token.present?
      next false if token.present? && !(importing? && reread_token == token)

      yield
    end
  end

  # When a reread's job starts and still holds its own claim: the previous
  # reading goes, rows and all. A delayed job from an earlier attempt returns
  # false, leaving a newer reread or a publish intact. The token is kept so a retry after this
  # cleanup still owns the import; it is released when the job reaches a terminal status.
  def clear_reading!(reread_token: nil)
    with_lock do
      return false if reread_token.present? && !(importing? && self.reread_token == reread_token)

      release_reconciliations!(account_id)
      rows.delete_all
      self.class.reset_counters(id, :rows)
      update!(ai_summary: nil, document_type: nil, extracted_data: nil, extraction_checks: nil, read_with: nil, read_model: nil,
              error: nil)
      true
    end
  end

  # One reader per record, so a job's ReadPdf and extraction share one download and text layer.
  def pdf_reading = @pdf_reading ||= Ai::PdfReading.new(content: pdf_file_content, filename: pdf_filename, family:)

  def bank_statement?
    document_type == "bank_statement"
  end

  def statement_with_transactions?
    document_type.in?(Ai::PdfReading::STATEMENT_TYPES)
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def generate_rows_from_extracted_data
    transaction do
      # insert_all! below bypasses ActiveRecord, so the `rows` association is
      # never populated with what it wrote. Reload before destroying, or a second
      # call on the same in-memory record (assign_account! regenerating after
      # ProcessPdfJob already generated) clears a stale empty collection, deletes
      # nothing, and collides on (import_id, source_row_number).
      rows.reload.destroy_all

      unless has_extracted_transactions?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency
      candidates = extracted_transactions.map.with_index(1) do |txn, index|
        Import::Row.new(
          import: self,
          source_row_number: index,
          date: format_date_for_import(txn["date"]),
          amount: txn["amount"].to_s,
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          currency: currency
        )
      end

      unmatched, matched_entries = partition_already_recorded(candidates)

      reconcile_entries!(matched_entries)

      mapped_rows = unmatched.map.with_index(1) do |row, index|
        {
          import_id: id,
          source_row_number: index,
          date: row.date,
          amount: row.amount,
          name: row.name,
          category: row.category,
          notes: row.notes,
          currency: row.currency
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      # Drop the now-stale association cache so later reads (sync_mappings, the
      # view) see what was actually written.
      rows.reset
      update_column(:rows_count, mapped_rows.size)
    end
  end

  # Transactions this statement reconciled against records that already existed.
  # Derived from the statement link rather than stored, so it cannot go stale.
  def reconciled_entries
    return Entry.none if account_statement.blank?

    Entry.reconciled_by_statement(account_statement)
  end

  def extraction_dependencies = Array(extracted_data&.dig(RECONCILED_IDS_KEY)).map(&:to_s)

  # The half of reconciled_entries this import did not create -- transactions the
  # account already held when the statement arrived. Everything this import
  # creates is born reconciled too, so the two have to be told apart before
  # either count means anything.
  def already_recorded_entries
    reconciled_entries.where.not(id: entries.select(:id))
  end

  # The next three are memoized because the summary dialog and the review screen
  # each read them more than once, and every read is its own COUNT -- rendering
  # the dialog issued roughly fifteen queries for a static summary. They report
  # a finished outcome for display, so a value cached for the life of the
  # request is what callers want; anything re-judging the import recomputes from
  # the entries directly. (`||=` is safe here: 0 is truthy in Ruby.)
  def already_recorded_count
    @already_recorded_count ||= already_recorded_entries.count
  end

  def imported_count
    @imported_count ||= entries.count
  end

  # Rows still on offer. import! creates an entry per row and leaves the rows in
  # place as the record of what was published, so past that point rows_count is
  # a history, not a queue. Memoized mostly for data_committed?, which is two
  # more EXISTS queries every time it is asked.
  def awaiting_review_count
    @awaiting_review_count ||= data_committed? ? 0 : rows_count
  end

  # No query: extracted_data is already in memory.
  def extracted_count
    extracted_transactions.size
  end

  # Whether the statement described transactions the account already had. The
  # difference between "nothing to import" and "nothing was found".
  def reconciled_anything?
    already_recorded_count.positive?
  end

  # The reading that queued the email goes with it: a reread before it's delivered would otherwise
  # change what it says.
  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self,
      reading: { document_type:, summary: ai_summary, failed_checks: }
    ).next_steps.deliver_later
  end

  def uploaded?
    pdf_uploaded?
  end

  def configured?
    ai_processed? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    account.present? && statement_with_transactions? && cleaned? && mappings.all?(&:valid?)
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    account.present? && statement_with_transactions? && super
  end

  def column_keys
    %i[date amount name category notes]
  end

  def requires_csv_workflow?
    false
  end

  def pdf_file_content
    return @pdf_file_content if defined?(@pdf_file_content)
    return @pdf_file_content = account_statement.original_file.download if statement_backed?

    @pdf_file_content = pdf_file.download if pdf_file.attached?
  end

  def pdf_filename
    return account_statement.filename if statement_backed?

    pdf_file.filename.to_s if pdf_file.attached?
  end

  def statement_backed?
    account_statement&.original_file&.attached?
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    base = []
    # Only include CategoryMapping if rows have non-empty categories
    base << Import::CategoryMapping if rows.where.not(category: [ nil, "" ]).exists?
    # Note: PDF imports use direct account selection in the UI, not AccountMapping
    # AccountMapping is designed for CSV imports where rows have different account values
    base
  end

  # A reread can replace rows that had categories with rows that have none. mapping_steps then
  # has no category step, so the superclass leaves the old mapping behind and publishing creates
  # an obsolete category. Drop mappings whose key no longer occurs in the rows.
  def sync_mappings
    super
    keys = rows.where.not(category: [ nil, "" ]).distinct.pluck(:category)
    mappings.where(type: Import::CategoryMapping.name).where.not(key: keys).destroy_all
  end

  private
    def requested_way = read_as.presence&.to_sym || :auto

    # A shared entry can be owned by only one import at a time. Another reading on the same
    # statement and account that recorded the same entry as its dependency still needs the mark,
    # so clearing this reading reassigns ownership to it rather than dropping the evidence.
    def surviving_owners_for(entry_ids, account_scope_id)
      return {} if entry_ids.empty?

      wanted = entry_ids.map(&:to_s)
      self.class.where(account_id: account_scope_id, account_statement_id:).where.not(id:).find_each.each_with_object({}) do |other, owners|
        (other.extraction_dependencies & wanted).each { owners[_1] ||= other.id }
      end
    end

    # A statement's posting date routinely differs by a day or two from the date
    # a provider recorded for the same transaction, so matching allows a small
    # window rather than demanding an exact date.
    RECONCILIATION_DATE_WINDOW = 3

    # Splits candidate rows into those that are genuinely new and the existing
    # entries the rest already correspond to. Matching is per-account, so with no
    # account assigned yet every row is treated as new and judged again once the
    # user picks one (see assign_account!).
    def partition_already_recorded(candidates)
      return [ candidates, [] ] if account.blank?

      adapter = Account::ProviderImportAdapter.new(account)
      claimed = []
      unmatched = []
      matched = []

      candidates.each do |row|
        if (existing = already_recorded_entry(adapter, row, claimed))
          claimed << existing.id
          matched << existing
        else
          unmatched << row
        end
      end

      [ unmatched, matched ]
    end

    # Name is deliberately not part of the match: statement descriptions and
    # provider names for the same transaction rarely agree, and the adapter makes
    # the same choice for provider sync.
    def already_recorded_entry(adapter, row, claimed)
      adapter.find_duplicate_transaction(
        date: row.date_iso,
        amount: row.signed_amount,
        currency: row.currency,
        exclude_entry_ids: claimed,
        date_window: RECONCILIATION_DATE_WINDOW,
        include_provider_entries: true
      )
    rescue ArgumentError, TypeError => e # Date::Error subclasses ArgumentError
      # A row whose date or amount will not parse cannot be judged. Offer it for
      # import rather than dropping it silently -- the review step surfaces it.
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: could not evaluate statement row for reconciliation (#{e.class})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement_id,
          source_row_number: row.source_row_number,
          raw_date: row.date,
          raw_amount: row.amount,
          error_class: e.class.name
        }
      )
      nil
    end

    def reconcile_entries!(entries, at: Time.current)
      return if entries.blank?

      ids = entries.map { _1.id.to_s }
      Entry.where(id: ids).update_all(
        reconciled_at: at,
        reconciled_by_statement_id: account_statement&.id,
        reconciled_by_import_id: id,
        updated_at: at
      )
      data = extracted_data.to_h
      recorded = Array(data[RECONCILED_IDS_KEY])
      data[RECONCILED_IDS_KEY] = (recorded + ids).uniq
      update_column(:extracted_data, data)
    end

    # Regeneration can empty the row set (everything now matches) or refill it
    # (the new account matches nothing). Status has to follow, using the same
    # rule ProcessPdfJob applies after initial processing -- otherwise a
    # fully-matched import sits at pending with no rows, which renders as the
    # processing screen forever and cannot be restarted.
    def refresh_status_after_regeneration!
      return if data_committed?
      return unless pending? || complete?

      target = statement_with_transactions? && rows_count > 0 ? "pending" : "complete"
      update!(status: target) unless status.to_s == target
    end

    # Releases the marks this import wrote on one account's entries. Another import on the same
    # statement may rely on a mark too: a mark another reading still depends on is handed to it, a
    # mark this import solely supported is cleared, and so are older statement-only marks from
    # before owner ids existed. A mark another import owns is never this import's to release, and
    # every write re-checks the owner, so a mark another import took meanwhile is left alone. A NULL
    # statement id matches nothing.
    def release_reconciliations!(account_scope_id)
      return if account_scope_id.blank?

      now = Time.current
      owned = Entry.where(account_id: account_scope_id, reconciled_by_import_id: id)
      survivors = surviving_owners_for(owned.pluck(:id), account_scope_id)
      survivors.each do |entry_id, owner_id|
        owned.where(id: entry_id).update_all(reconciled_by_import_id: owner_id, updated_at: now)
      end
      owned.where.not(id: survivors.keys)
           .update_all(reconciled_at: nil, reconciled_by_statement_id: nil, reconciled_by_import_id: nil, updated_at: now)
      return unless (statement_id = account_statement&.id)

      Entry.where(account_id: account_scope_id, reconciled_by_import_id: nil, reconciled_by_statement_id: statement_id)
           .update_all(reconciled_at: nil, reconciled_by_statement_id: nil, updated_at: now)
    end

    # Reverting a statement import unwinds its evidence as well as its rows. The
    # entries it created are already destroyed by the time this runs; the ones it
    # only matched keep marks this statement no longer backs. Releasing and then
    # regenerating re-judges every statement line against what the account
    # actually holds now, so the review screen offers exactly what is missing.
    def revert_derived_state!
      release_reconciliations!(account_id)
      return unless has_extracted_transactions?

      generate_rows_from_extracted_data
      # A line that matched at publish time carried no row and so no mapping.
      # If it no longer matches it is a row again, and needs one.
      sync_mappings
    end

    # A statement whose every line still matches something -- a provider-synced
    # account, say -- reverts to zero rows. Returning that to pending renders the
    # processing screen with no way out, so an import with nothing left to offer
    # finishes as complete, the same way refresh_status_after_regeneration! ends
    # a fully reconciled import.
    def status_after_revert
      statement_with_transactions? && rows_count > 0 ? :pending : :complete
    end

    def format_date_for_import(date_str)
      return "" if date_str.blank?

      Date.parse(date_str).strftime(date_format)
    rescue ArgumentError
      date_str.to_s
    end

    def account_statement_matches_import
      return if account_statement.blank? || (account_statement.family_id == family_id && account_statement.pdf?)

      errors.add(:account_statement, :invalid)
    end

    def sync_statement_metadata_from_extracted_data(data)
      return unless statement_backed?

      start_date = data.dig("period", "start_date").presence
      end_date = data.dig("period", "end_date").presence
      opening_bal = data["opening_balance"]
      closing_bal = data["closing_balance"]
      bank_name = data["bank_name"].presence
      last4 = data["account_number"].presence&.to_s&.last(4)
      currency = data["currency"].presence || account_statement.sanitized_parser_output&.dig("extracted_currency").presence

      apply_statement_metadata_updates(
        start_date: start_date,
        end_date: end_date,
        opening_balance: opening_bal,
        closing_balance: closing_bal,
        institution_name: bank_name,
        account_last4: last4,
        currency: currency
      )
    end

    def sync_statement_metadata_from_process_result(result)
      return unless statement_backed?
      return unless result.respond_to?(:extracted_data) && result.extracted_data.is_a?(Hash)

      data = result.extracted_data.deep_stringify_keys
      start_date = data["statement_period_start"].presence
      end_date = data["statement_period_end"].presence
      opening_bal = data["opening_balance"]
      closing_bal = data["closing_balance"]
      institution = data["institution_name"].presence
      currency = data["currency"].presence || account_statement.sanitized_parser_output&.dig("extracted_currency").presence

      apply_statement_metadata_updates(
        start_date: start_date,
        end_date: end_date,
        opening_balance: opening_bal,
        closing_balance: closing_bal,
        institution_name: institution,
        account_last4: nil,
        currency: currency
      )
    end

    def apply_statement_metadata_updates(start_date:, end_date:, opening_balance:, closing_balance:, institution_name:, account_last4:, currency: nil)
      updates = {}

      if currency.present?
        if account_statement.currency.blank? && account_statement.account_id.blank?
          updates[:currency] = currency.to_s.upcase
        end
        parser_output = (account_statement.sanitized_parser_output || {}).dup
        if parser_output["extracted_currency"] != currency.to_s.upcase
          parser_output["extracted_currency"] = currency.to_s.upcase
          updates[:sanitized_parser_output] = parser_output
        end
      end

      # Only sync balances when currency is compatible with the statement's currency,
      # matching AccountStatement::MetadataDetector#detect_from_pdf behavior.
      target_currency = updates[:currency] || account_statement.statement_currency
      currency_compatible = currency.blank? || target_currency.blank? || currency.to_s.casecmp?(target_currency)

      if currency_compatible
        updates[:opening_balance] = opening_balance if opening_balance.present?
        updates[:closing_balance] = closing_balance if closing_balance.present?
      else
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: extracted balance currency '#{currency}' does not match statement currency '#{target_currency}'",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            extracted_currency: currency,
            statement_currency: target_currency
          }
        )
      end

      bounded_institution = institution_name.presence&.to_s&.strip&.first(200)&.presence
      updates[:institution_name_hint] = bounded_institution if bounded_institution && account_statement.institution_name_hint.blank?
      updates[:account_last4_hint] = account_last4 if account_last4.present? && account_statement.account_last4_hint.blank?

      parsed_start = parse_statement_date(start_date)
      parsed_end = parse_statement_date(end_date)

      proposed_start = parsed_start || account_statement.period_start_on
      proposed_end = parsed_end || account_statement.period_end_on

      if proposed_start && proposed_end && proposed_start > proposed_end
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: extracted statement period is inverted or conflicts with existing period",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            parsed_start: parsed_start&.iso8601,
            parsed_end: parsed_end&.iso8601,
            existing_start: account_statement.period_start_on&.iso8601,
            existing_end: account_statement.period_end_on&.iso8601
          }
        )
      else
        updates[:period_start_on] = parsed_start if parsed_start
        updates[:period_end_on] = parsed_end if parsed_end
      end

      return if updates.empty?

      unless account_statement.update(updates)
        DebugLogEntry.capture(
          category: "import",
          level: "warn",
          message: "PdfImport: failed to sync statement metadata (#{account_statement.errors.full_messages.to_sentence})",
          source: "pdf_import",
          family: family,
          account: account,
          metadata: {
            import_id: id,
            account_statement_id: account_statement.id,
            updates: updates,
            errors: account_statement.errors.messages
          }
        )
      end
    end

    def parse_statement_date(date_str)
      return nil if date_str.blank?

      date = date_str.is_a?(Date) ? date_str : Date.parse(date_str.to_s)
      return date if Import.reasonable_date_range.cover?(date)

      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: statement date '#{date_str}' falls outside reasonable date range",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement&.id,
          raw_date: date_str,
          parsed_date: date.iso8601
        }
      )
      nil
    rescue Date::Error, ArgumentError => e
      DebugLogEntry.capture(
        category: "import",
        level: "warn",
        message: "PdfImport: failed to parse statement date '#{date_str}' (#{e.message})",
        source: "pdf_import",
        family: family,
        account: account,
        metadata: {
          import_id: id,
          account_statement_id: account_statement&.id,
          raw_date: date_str
        }
      )
      nil
    end
end
