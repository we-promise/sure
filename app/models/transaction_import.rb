class TransactionImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new # Track entries we've already claimed in this import
      seen_external_ids = {} # Track external_ids within the same batch (first row wins)

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

        if row.external_id.present?
          # Skip intra-batch duplicates (first row wins)
          batch_key = "#{mapped_account.id}:#{row.external_id}"
          next if seen_external_ids.key?(batch_key)
          seen_external_ids[batch_key] = true

          # External ID-based deduplication: find existing entry by external_id + source
          existing_entry = mapped_account.entries.find_by(external_id: row.external_id, source: "csv_import")

          if existing_entry
            update_existing_entry(existing_entry, category: category, tags: tags, notes: row.notes)
            updated_entries << existing_entry
            claimed_entry_ids.add(existing_entry.id)
          else
            # Fallback to legacy date/amount/name dedup for entries imported before external_id support.
            # Note: find_duplicate_transaction only matches entries with external_id IS NULL,
            # so entries already backfilled with an external_id from a prior import won't be
            # matched again here. This is intentional — once an entry has an external_id,
            # deduplication should happen via the external_id path above.
            legacy_match = find_legacy_duplicate(mapped_account, row, effective_currency, claimed_entry_ids)

            if legacy_match
              update_existing_entry(legacy_match, category: category, tags: tags, notes: row.notes,
                                    extra_attrs: { external_id: row.external_id, source: "csv_import" })
              updated_entries << legacy_match
              claimed_entry_ids.add(legacy_match.id)
            else
              new_transactions << build_new_transaction(
                account: mapped_account, row: row, category: category, tags: tags,
                currency: effective_currency, external_id: row.external_id, source: "csv_import"
              )
            end
          end
        else
          # Legacy name/date/amount-based deduplication
          duplicate_entry = find_legacy_duplicate(mapped_account, row, effective_currency, claimed_entry_ids)

          if duplicate_entry
            update_existing_entry(duplicate_entry, category: category, tags: tags, notes: row.notes)
            updated_entries << duplicate_entry
            claimed_entry_ids.add(duplicate_entry.id)
          else
            new_transactions << build_new_transaction(
              account: mapped_account, row: row, category: category, tags: tags,
              currency: effective_currency
            )
          end
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
    template = <<-CSV
      date*,amount*,name,currency,category,tags,account,notes,external_id
      05/15/2024,-45.99,Grocery Store,USD,Food,groceries|essentials,Checking Account,Monthly grocery run,TXN-001
      05/16/2024,1500.00,Salary,,Income,,Main Account,,TXN-002
      05/17/2024,-12.50,Coffee Shop,,,coffee,,,TXN-003
    CSV

    csv = CSV.parse(template, headers: true)
    csv.delete("account") if account.present?
    csv
  end

  private

    def update_existing_entry(entry, category:, tags:, notes:, extra_attrs: {})
      entry.transaction.category = category if category.present?
      entry.transaction.tags = tags if tags.any?
      entry.notes = notes if notes.present?
      entry.assign_attributes(import: self, import_locked: true, **extra_attrs)
    end

    def build_new_transaction(account:, row:, category:, tags:, currency:, external_id: nil, source: nil)
      Transaction.new(
        category: category,
        tags: tags,
        entry: Entry.new(
          account: account,
          date: row.date_iso,
          amount: row.signed_amount,
          name: row.name,
          currency: currency,
          notes: row.notes,
          external_id: external_id,
          source: source,
          import: self,
          import_locked: true
        )
      )
    end

    def find_legacy_duplicate(account, row, currency, claimed_entry_ids)
      adapter = Account::ProviderImportAdapter.new(account)
      adapter.find_duplicate_transaction(
        date: row.date_iso,
        amount: row.signed_amount,
        currency: currency,
        name: row.name,
        exclude_entry_ids: claimed_entry_ids
      )
    end
end
