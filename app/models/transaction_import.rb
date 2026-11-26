class TransactionImport < Import
  SURE_EXPORT_SETTINGS = {
    amount_type_strategy: "signed_amount",
    signage_convention: "inflows_negative",
    date_format: "%Y-%m-%d",
    number_format: "1,234.56",
    rows_to_skip: 0
  }.freeze

  # The column label for each column of Family::DataExporter::TRANSACTIONS_CSV_HEADERS, in its order.
  SURE_EXPORT_LABELS = %i[
    date_col_label account_col_label amount_col_label name_col_label
    category_col_label tags_col_label notes_col_label currency_col_label
  ].zip(Family::DataExporter::TRANSACTIONS_CSV_HEADERS).to_h.freeze

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      updated_entries = []
      ordered_entries = [] # every imported entry, new AND matched, in CSV row order
      claimed_entry_ids = Set.new # Track entries we've already claimed in this import

      rows.ordered.each_with_index do |row, index|
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
        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: effective_currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          # Update existing transaction instead of creating a new one. It keeps
          # its original import (if any): the entry belongs to whoever created
          # it, so reverting or deleting this import must not destroy it.
          duplicate_entry.transaction.category = category if category.present?
          duplicate_entry.transaction.tags = tags if tags.any?
          duplicate_entry.notes = row.notes if row.notes.present?
          duplicate_entry.import_locked = true  # Protect from provider sync overwrites
          updated_entries << duplicate_entry
          ordered_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          # Create new transaction (no duplicate found)
          # Mark as import_locked to protect from provider sync overwrites
          new_transaction = Transaction.new(
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
          new_transactions << new_transaction
          ordered_entries << new_transaction.entry
        end
      end

      # reverse_chronological breaks date ties by created_at and then by a random UUID
      # id, and a bulk insert stamps every row with the same created_at. Stamp EVERY
      # imported entry -- new AND matched duplicates -- in CSV row order, so the first
      # CSV row keeps the latest created_at and a same-day import (even one mixing new
      # rows with matched existing ones) renders in the CSV's order.
      import_time = Time.current
      ordered_entries.each_with_index do |entry, index|
        ordered_time = import_time - index.milliseconds
        entry.created_at = ordered_time
        entry.updated_at = ordered_time
      end

      # Save updated entries first (persists their re-ordered created_at)
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

  # Sure's own transactions.csv export keeps the stored sign (outflows positive),
  # ISO dates and plain decimals, so a re-import of it needs matching settings.
  # Call after assigning a new raw_file_str and before saving it.
  def preset_for_uploaded_csv
    if sure_export_csv?(raw_file_str, col_sep)
      assign_attributes(SURE_EXPORT_SETTINGS)
    elsif sure_export_csv?(raw_file_str_was, col_sep_was)
      assign_attributes(amount_type_strategy: "signed_amount", signage_convention: "inflows_positive", date_format: family.date_format)
    end
  end

  # A template from another bank's file would bring its own sign, formats,
  # column names and skipped rows, none of which fit a Sure export.
  def apply_template!(import_template)
    return super unless sure_export_csv?(raw_file_str, col_sep)

    update!(template_attributes(import_template).merge(SURE_EXPORT_SETTINGS.stringify_keys, sure_export_labels.stringify_keys))
  end

  private
    def sure_export_csv?(csv_str, separator)
      # A dropped file is read as binary bytes; read it as UTF-8 so a BOM or
      # non-ASCII characters elsewhere in the file cannot raise.
      headers = header_record(utf8_without_bom(csv_str), separator).map { |header| export_header_key(header) }
      headers.any? && (Family::DataExporter::TRANSACTIONS_CSV_HEADERS - headers).empty?
    end

    # Column labels must match the parsed headers exactly, which keep a BOM and
    # the file's own spelling (e.g. "Date"), so map each export column to it.
    # Read from the file itself: a Sure export skips no rows, whatever
    # rows_to_skip the import had before the template reset it.
    def sure_export_labels
      headers = header_record(raw_file_str, col_sep)
      SURE_EXPORT_LABELS.transform_values do |label|
        headers.find { |header| export_header_key(header) == label } || label
      end
    end

    # The first CSV record, read like Import.parse_csv_str reads headers:
    # leading blank lines are skipped and a quoted field may span lines.
    def header_record(csv_str, separator)
      CSV.new(csv_str.to_s.strip, col_sep: separator.presence || ",", liberal_parsing: true).shift.to_a
    rescue CSV::MalformedCSVError
      []
    end

    def export_header_key(header)
      utf8_without_bom(header).strip.downcase
    end

    def utf8_without_bom(str)
      str.to_s.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("\uFEFF")
    end
end
