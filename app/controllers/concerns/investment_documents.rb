# Shared by the contributions and equity grants controllers: CSV import, and
# uploading statement PDFs that the family's AI provider then reads.
module InvestmentDocuments
  extend ActiveSupport::Concern

  MAX_CSV_BYTES = 2.megabytes

  private
    def set_writable_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      require_account_permission!(@account)
    end

    def investment_tab_path(tab)
      account_path(@account, tab: tab)
    end

    def import_csv(kind:, tab:, default_ticker: nil)
      file = params[:file]
      if !file.respond_to?(:read) || file.size > MAX_CSV_BYTES
        return redirect_to investment_tab_path(tab), alert: t("investment_documents.csv_missing")
      end

      result = InvestmentCsvImport.new(account: @account, content: file.read, kind: kind, default_ticker: default_ticker).import!
      notice = t("investment_documents.csv_imported", created: result.created, skipped: result.skipped)
      notice += " " + result.errors.join(" ") if result.errors.any?
      redirect_to investment_tab_path(tab), notice: notice
    rescue ArgumentError => e
      redirect_to investment_tab_path(tab), alert: e.message
    end

    # Stores each PDF as an account statement (the same place the Statements
    # tab uses) and queues it to be read.
    def upload_documents(kind:, tab:)
      files = Array(params[:files]).select { |file| file.respond_to?(:read) }
      return redirect_to investment_tab_path(tab), alert: t("investment_documents.no_files") if files.empty?

      queued = 0
      problems = []
      files.each do |file|
        prepared = AccountStatement.prepare_upload!(file)
        statement = AccountStatement.create_from_prepared_upload!(family: Current.family, account: @account, prepared_upload: prepared)
        queued += queue_read(statement, kind)
      rescue AccountStatement::DuplicateUploadError => e
        queued += queue_read(e.statement, kind) if e.statement.account_id == @account.id
      rescue AccountStatement::InvalidUploadError, ActiveRecord::RecordInvalid
        problems << file.original_filename.to_s
      end

      flash_message = t("investment_documents.queued", count: queued)
      flash_message += " " + t("investment_documents.rejected", files: problems.join(", ")) if problems.any?
      redirect_to investment_tab_path(tab), notice: flash_message
    end

    # Reads every PDF statement on the account that hasn't produced any records
    # of this kind yet.
    def read_existing_statements(kind:, tab:)
      read_ids = kind == "contributions" ? @account.account_contributions.where.not(account_statement_id: nil).distinct.pluck(:account_statement_id) :
                                           @account.equity_grants.where.not(account_statement_id: nil).distinct.pluck(:account_statement_id)
      statements = @account.account_statements.where(content_type: "application/pdf").where.not(id: read_ids)
      queued = statements.sum { |statement| queue_read(statement, kind) }
      redirect_to investment_tab_path(tab), notice: t("investment_documents.queued", count: queued)
    end

    def queue_read(statement, kind)
      return 0 unless statement.content_type == "application/pdf" && AccountStatement::InvestmentDataReader.available?

      InvestmentDocumentReadJob.perform_later(statement, kind)
      1
    end
end
