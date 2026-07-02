class TransactionImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new # Track entries we've already claimed in this import
      claimed_external_ids = {} # [account_id, external_id] (this run) => Entry we created/updated, for in-batch dedup

      rows.each_with_index do |row, index|
        mapped_account = if account
          account
        else
          mappings.accounts.mappable_for(row.account)
        end

        # Guard against nil account - this happens when an account name in CSV is not mapped
        if mapped_account.nil?
          row_number = index + 1
          account_name = row.account.presence || "(blank)"
          error_message = "Row #{row_number}: Account '#{account_name}' is not mapped to an existing account. " \
                         "Please map this account in the import configuration."
          errors.add(:base, error_message)
          raise Import::MappingError, error_message
        end

        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact

        # Use account's currency when no currency column was mapped in CSV, with family currency as fallback
        effective_currency = currency_col_label.present? ? row.currency : (mapped_account.currency.presence || family.currency)

        # Check for duplicate transactions using the adapter's deduplication logic
        # Pass claimed_entry_ids to exclude entries we've already matched in this import
        # This ensures identical rows within the CSV are all imported as separate transactions
        external_id = row.external_id.presence
        # Scope the in-batch claim by account: the same bank id can legitimately
        # appear under two different accounts in one multi-account CSV, and those
        # must not fold together (the persisted lookup below is account-scoped too).
        external_id_claim_key = [ mapped_account.id, external_id ] if external_id

        # In-batch dedup: a repeated external_id within the same CSV must fold
        # into the entry we already created/updated this run. The persisted
        # lookup below can't see a still-pending new_transactions record, so
        # without this two rows sharing an id would both be inserted.
        if external_id_claim_key && (claimed = claimed_external_ids[external_id_claim_key])
          apply_row_updates(claimed, category: category, tags: tags, notes: row.notes)
          next
        end

        # Prefer an exact external_id match when the CSV carries a unique
        # transaction id (robust dedup, e.g. re-importing the same file), and
        # fall back to the existing date/amount/name heuristic otherwise.
        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry =
          (external_id && mapped_account.entries.where(entryable_type: "Transaction").where.not(id: claimed_entry_ids.to_a).find_by(external_id: external_id)) ||
          adapter.find_duplicate_transaction(
            date: row.date_iso,
            amount: row.signed_amount,
            currency: effective_currency,
            name: row.name,
            exclude_entry_ids: claimed_entry_ids
          )

        if duplicate_entry
          # Update existing transaction instead of creating a new one
          apply_row_updates(duplicate_entry, category: category, tags: tags, notes: row.notes)
          # Only backfill external_id when the matched entry doesn't already have
          # one. Never overwrite a different existing id (e.g. a provider's), so
          # we don't clobber the canonical identifier used for future dedup.
          duplicate_entry.external_id = external_id if external_id && duplicate_entry.external_id.blank?
          duplicate_entry.import = self
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
          claimed_external_ids[external_id_claim_key] = duplicate_entry if external_id_claim_key
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          new_entry = Entry.new(
            account: mapped_account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: effective_currency,
            notes: row.notes,
            external_id: external_id,
            import: self,
            import_locked: true
          )
          new_transaction = Transaction.new(category: category, tags: tags)
          # Link both directions explicitly: recursive import! persists the entry
          # via transaction.entry, while the in-batch merge reads entry.transaction.
          new_transaction.entry = new_entry
          new_entry.entryable = new_transaction
          new_transactions << new_transaction
          claimed_external_ids[external_id_claim_key] = new_entry if external_id_claim_key
        end
      end

      # Save updated entries first
      updated_entries.each do |entry|
        entry.transaction.save!
        entry.save!
      end

      # Bulk import new transactions
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    base = %i[date amount name currency category tags notes external_id]
    base.unshift(:account) if account.nil?
    base
  end

  def mapping_steps
    base = [ Import::CategoryMapping, Import::TagMapping ]
    base << Import::AccountMapping if account.nil?
    base
  end

  def selectable_amount_type_values
    return [] if entity_type_col_label.nil?

    csv_rows.map { |row| row[entity_type_col_label] }.uniq
  end

  def csv_template
    template = <<~CSV
      date*,amount*,name,currency,category,tags,account,notes
      2024-05-15,-45.99,Grocery Store,USD,Food,groceries|essentials,Checking Account,Monthly grocery run
      2024-05-16,1500.00,Salary,,Income,,Main Account,
      2024-05-17,-12.50,Coffee Shop,,,coffee,,
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private

    # Applies a CSV row's category/tags/notes onto an entry we are either
    # updating (a persisted duplicate) or building (a pending new entry). Used by
    # both the duplicate path and the in-batch dedup merge so the two stay in
    # sync. Tags are unioned so a later duplicate row never drops earlier tags.
    def apply_row_updates(entry, category:, tags:, notes:)
      txn = entry.transaction
      txn.category = category if category.present?
      txn.tags = (txn.tags | tags) if tags.any?
      entry.notes = notes if notes.present?
    end
end
