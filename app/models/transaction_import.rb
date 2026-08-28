class TransactionImport < Import
  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new # Track entries we've already claimed in this import

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
        #
        # Only rows carrying a real CSV name may claim a provider-synced entry.
        # A blank name cell falls back to default_row_name, so row.name is never
        # actually blank -- gating on presence alone would always be true and let
        # a placeholder row match a provider entry on date+amount+placeholder.
        # Named rows still skip already-synced overlap (Enable Banking's ~90-day
        # window); placeholder rows only reconcile against manual/CSV entries.
        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: effective_currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids,
          include_provider_entries: csv_provided_name?(row)
        )

        if duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)

          # Already synced from a provider — skip creating a CSV duplicate and
          # do not mark the provider-owned row import_locked.
          next if duplicate_entry.external_id.present?

          # Update existing manual/CSV transaction instead of creating a new one
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import = self
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          updated_entries << duplicate_entry
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          new_transactions << Transaction.new(
            category: category,
            tags: tags,
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: effective_currency,
              notes: row.notes,
              import: self,
              import_locked: true
            )
          )
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
    base = %i[date amount name currency category tags notes]
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
    # True when the row's name came from the CSV rather than the
    # default_row_name placeholder substituted for a blank cell. A row whose
    # name cell literally holds the placeholder text still counts as provided,
    # so it reconciles against provider-synced history like any other named row.
    def csv_provided_name?(row)
      return false if row.name.blank?
      return true unless row.name == default_row_name

      csv_name_cells[row.source_row_number].present?
    end

    # Maps source_row_number (1-based, assigned in Import#generate_rows_from_csv)
    # to the raw name cell, so a supplied placeholder is distinguishable from a
    # blank one. Empty without a CSV behind the import, which keeps the
    # conservative "not provided" answer.
    def csv_name_cells
      @csv_name_cells ||= if raw_file_str.blank?
        {}
      else
        csv_rows.each_with_index.to_h do |csv_row, index|
          [ index + 1, csv_value(csv_row, name_col_label, "name") ]
        end
      end
    end
end
