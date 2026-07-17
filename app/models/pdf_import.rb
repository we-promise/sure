class PdfImport < Import
  has_one_attached :pdf_file, dependent: :purge_later

  validates :document_type, inclusion: { in: DOCUMENT_TYPES }, allow_nil: true
  validate :account_statement_matches_import

  class << self
    def create_from_upload!(family:, file:, user:)
      statement = AccountStatement.create_from_prepared_upload!(
        family: family,
        account: nil,
        prepared_upload: AccountStatement.prepare_upload!(file)
      )

      create_from_statement!(statement: statement)
    rescue AccountStatement::DuplicateUploadError => e
      raise unless e.statement.manageable_by?(user)

      create_from_statement!(statement: e.statement)
    end

    def create_from_statement!(statement:)
      reusable_import = statement.latest_reusable_pdf_import
      return reusable_import if reusable_import &&
                                reusable_import.account_id == statement.account_id &&
                                reusable_import.date_format == statement.family.date_format

      create!(family: statement.family, account: statement.account, account_statement: statement, date_format: statement.family.date_format, status: :pending)
    end
  end

  # A PdfImport's importing status is a processing claim (AI extraction or
  # publish). Release a lost claim back to pending so the user can re-trigger
  # processing, mirroring ProcessPdfJob's own reclaim; lost reverts keep the
  # base revert_failed behavior.
  def force_fail!(error_message = Import.lost_error_message)
    return super if reverting?

    with_lock do
      return false unless presumed_lost?

      update!(status: :pending)
    end

    true
  end

  def import!
    raise "Account required for PDF import" unless account.present?

    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = rows.map do |row|
        category = mappings.categories.mappable_for(row.category)

        Transaction.new(
          category: category,
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: row.currency,
            notes: row.notes,
            import: self,
            import_locked: true
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def assign_account!(account)
    transaction do
      update!(account: account)
      if (statement = account_statement)
        statement.lock!
        statement.link_to_account!(account) if statement.account_id != account.id
      end
    end
  end

  def pdf_uploaded?
    statement_backed? || pdf_file.attached?
  end

  def ai_processed?
    ai_summary.present?
  end

  def process_with_ai_later
    return false unless with_lock { pending? && !ai_processed? && rows_count.zero? && pdf_uploaded? && update!(status: :importing) }

    begin
      ProcessPdfJob.perform_later(self)
      true
    rescue StandardError => e
      Rails.logger.error("Failed to enqueue PDF processing for import #{id}: #{e.class.name} - #{e.message}")
      reload.with_lock { update!(status: :pending) }
      false
    end
  end

  def process_with_ai
    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # process_pdf (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise "AI provider not configured" unless provider
    raise "AI provider does not support PDF processing" unless provider.supports_pdf_processing?

    response = provider.process_pdf(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown PDF processing error"
      raise error_message
    end

    result = response.data
    update!(
      ai_summary: result.summary,
      document_type: result.document_type
    )

    result
  end

  def extract_transactions
    return unless statement_with_transactions?

    # Honors Setting.llm_provider (issue #2113) — Provider::Anthropic implements
    # extract_bank_statement (PR #1985).
    provider = Provider::Registry.preferred_llm_provider
    raise "AI provider not configured" unless provider

    response = provider.extract_bank_statement(
      pdf_content: pdf_file_content,
      family: family
    )

    unless response.success?
      error_message = response.error&.message || "Unknown extraction error"
      raise error_message
    end

    update!(extracted_data: response.data)
    response.data
  end

  def bank_statement?
    document_type == "bank_statement"
  end

  def statement_with_transactions?
    document_type.in?(%w[bank_statement credit_card_statement])
  end

  def has_extracted_transactions?
    extracted_data.present? && extracted_data["transactions"].present?
  end

  def extracted_transactions
    extracted_data&.dig("transactions") || []
  end

  def generate_rows_from_extracted_data
    transaction do
      rows.destroy_all

      unless has_extracted_transactions?
        update_column(:rows_count, 0)
        return
      end

      currency = account&.currency || family.currency

      mapped_rows = extracted_transactions.map.with_index(1) do |txn, index|
        {
          import_id: id,
          source_row_number: index,
          date: format_date_for_import(txn["date"]),
          amount: txn["amount"].to_s,
          name: txn["name"].to_s,
          category: txn["category"].to_s,
          notes: txn["notes"].to_s,
          currency: currency
        }
      end

      Import::Row.insert_all!(mapped_rows) if mapped_rows.any?
      update_column(:rows_count, mapped_rows.size)
    end
  end

  def send_next_steps_email(user)
    PdfImportMailer.with(
      user: user,
      pdf_import: self
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

  private

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
end
