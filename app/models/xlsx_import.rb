# Imports transactions from a multi-sheet .xlsx bank export (Crédit Mutuel /
# CIC "Vos comptes" workbook). Unlike the CSV flow, the file holds several
# accounts across separate sheets, so the user picks which sheets to import and
# maps each to an app account on a dedicated selection step. Mappings are keyed
# by the account number (RIB) stored on the account, so future exports — where
# new accounts may appear and monthly card sheets change name — keep working.
class XlsxImport < Import
  has_one_attached :xlsx_file, dependent: :purge_later

  MAX_XLSX_SIZE = 15.megabytes
  ALLOWED_XLSX_MIME_TYPES = %w[
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.ms-excel
    application/octet-stream
  ].freeze
  XLSX_EXTENSIONS = %w[.xlsx].freeze

  class << self
    def create_from_upload!(family:, file:)
      import = create!(type: name, family: family, date_format: family.date_format)
      import.xlsx_file.attach(
        io: file.open,
        filename: file.original_filename,
        content_type: file.content_type
      )
      import
    end

    def valid_upload?(file)
      ext = File.extname(file.original_filename.to_s).downcase
      XLSX_EXTENSIONS.include?(ext)
    end
  end

  # --- Workbook / detection -------------------------------------------------

  def workbook
    @workbook ||= Import::XlsxWorkbook.open(xlsx_file.download)
  end

  def detector
    @detector ||= Import::AccountSheetDetector.new(workbook)
  end

  def detected_sheets
    detector.detected_sheets
  end

  # The existing app account a sheet auto-maps to (RIB seen in a prior import).
  def suggested_account_for(detected)
    return nil if detected.account_key.blank?

    family.accounts.find_by(external_account_number: detected.account_key)
  end

  # --- Selection step -------------------------------------------------------

  # selections: array of { "sheet_name" =>, "selected" =>, "account_id" =>,
  # "account_name" => }. Resolves/creates the target account for each selected
  # sheet (persisting the RIB on the account), then regenerates rows.
  def apply_sheet_selections!(selections)
    chosen = Array(selections).select { |s| ActiveModel::Type::Boolean.new.cast(s["selected"]) }
    by_name = detected_sheets.index_by(&:sheet_name)

    transaction do
      pairs = chosen.filter_map do |selection|
        detected = by_name[selection["sheet_name"].to_s]
        next unless detected

        account = resolve_account(detected, selection)
        [ detected, account ]
      end

      generate_rows_from_sheets(pairs)
    end
  end

  def generate_rows_from_sheets(pairs)
    rows.destroy_all

    mapped_rows = []
    pairs.each do |detected, account|
      detector.transactions(detected).each do |txn|
        mapped_rows << {
          import_id: id,
          account: account.id, # resolved at import! time
          date: txn[:date].strftime(date_format),
          name: txn[:name].presence || default_row_name,
          amount: format_amount(txn[:amount]),
          currency: txn[:currency].presence || account.currency || family.currency
        }
      end
    end

    mapped_rows.each_with_index { |r, i| r[:source_row_number] = i + 1 }
    Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  # --- Publish --------------------------------------------------------------

  def import!
    transaction do
      accounts_by_id = family.accounts.where(id: rows.distinct.pluck(:account)).index_by(&:id)

      new_transactions = []
      updated_entries = []
      claimed_entry_ids = Set.new

      rows.each do |row|
        mapped_account = accounts_by_id[row.account]
        next if mapped_account.nil? # account removed mid-import; skip defensively

        adapter = Account::ProviderImportAdapter.new(mapped_account)
        duplicate_entry = adapter.find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: row.currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate_entry
          duplicate_entry.import = self
          duplicate_entry.import_locked = true
          updated_entries << duplicate_entry
          claimed_entry_ids.add(duplicate_entry.id)
        else
          new_transactions << Transaction.new(
            entry: Entry.new(
              account: mapped_account,
              date: row.date_iso,
              amount: row.signed_amount,
              name: row.name,
              currency: row.currency,
              import: self,
              import_locked: true
            )
          )
        end
      end

      updated_entries.each(&:save!)
      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  # --- Import flow hooks ----------------------------------------------------

  def requires_csv_workflow?
    false
  end

  def uploaded?
    xlsx_file.attached?
  end

  def configured?
    uploaded? && rows_count > 0
  end

  def cleaned?
    configured? && rows.all?(&:valid?)
  end

  def publishable?
    cleaned? && mappings.all?(&:valid?)
  end

  def cleaned_from_validation_stats?(invalid_rows_count:)
    configured? && invalid_rows_count.zero?
  end

  def publishable_from_validation_stats?(invalid_rows_count:)
    cleaned_from_validation_stats?(invalid_rows_count: invalid_rows_count) && mappings.all?(&:valid?)
  end

  def column_keys
    %i[date name amount currency]
  end

  def required_column_keys
    %i[date amount]
  end

  def mapping_steps
    [] # accounts are mapped on the sheet-selection step, not via Import::Mapping
  end

  def dry_run
    { transactions: rows_count }
  end

  private
    def resolve_account(detected, selection)
      account_id = selection["account_id"].to_s

      if account_id.present? && account_id != "new"
        account = family.accounts.find(account_id)
        # Persist the RIB so this account auto-maps on future imports.
        if detected.account_key.present? && account.external_account_number.blank?
          account.update!(external_account_number: detected.account_key)
        end
        return account
      end

      create_account_for(detected, selection["account_name"])
    end

    def create_account_for(detected, name_override)
      attrs = {
        name: name_override.presence || detected.account_name,
        balance: 0,
        currency: detected.currency.presence || family.currency,
        import: self,
        accountable: Depository.new
      }

      # Reuse the account previously mapped to this RIB; only fall back to a
      # blind create when the sheet has no usable account number.
      if detected.account_key.present?
        family.accounts.create_or_find_by!(external_account_number: detected.account_key) do |account|
          account.assign_attributes(attrs)
        end
      else
        family.accounts.create!(attrs)
      end
    end

    def format_amount(amount)
      # Canonical decimal string; Import::Row#signed_amount parses with .to_d and
      # applies the (default) signage convention.
      amount.to_d.to_s("F")
    end
end
