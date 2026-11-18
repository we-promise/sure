# Grants on a stock plan account: manual entry, CSV import, and grant
# documents read by the PDF-extraction AI route.
class EquityGrantsController < ApplicationController
  include AiFeatureGuard

  TAB = "grants".freeze
  MAX_CSV_BYTES = 2.megabytes

  before_action :set_writable_account, only: %i[create import upload read_statements]
  before_action :set_grant, only: %i[update destroy forfeit]
  requires_ai :extract_pdf, only: %i[upload read_statements]

  def create
    grant = @account.equity_grants.build(grant_params.merge(source: "manual"))

    if grant.save
      redirect_to grants_tab_path, notice: t(".created")
    else
      redirect_to grants_tab_path, alert: grant.errors.full_messages.to_sentence
    end
  end

  def update
    if @grant.update(grant_params)
      redirect_to grants_tab_path, notice: t(".updated")
    else
      redirect_to grants_tab_path, alert: @grant.errors.full_messages.to_sentence
    end
  end

  def destroy
    @grant.destroy!
    redirect_to grants_tab_path, notice: t(".deleted")
  end

  # Marks the grant's remaining units as forfeited from today, e.g. after
  # leaving the company. Vests after that date stop counting.
  def forfeit
    @grant.update!(forfeited_on: Date.current)
    redirect_to grants_tab_path, notice: t(".forfeited")
  end

  def import
    file = params[:file]
    return redirect_to grants_tab_path, alert: t(".csv_missing") if !file.respond_to?(:read) || file.size > MAX_CSV_BYTES

    result = EquityGrant::CsvImport.new(account: @account, content: file.read, default_ticker: params[:ticker].presence).import!
    notice = t(".imported", created: result.created, skipped: result.skipped)
    notice += " " + result.errors.join(" ") if result.errors.any?
    redirect_to grants_tab_path, notice: notice
  rescue ArgumentError => e
    redirect_to grants_tab_path, alert: e.message
  end

  # Stores each PDF as an account statement (it shows on the Statements tab
  # too) and queues it to be read.
  def upload
    files = Array(params[:files]).select { |file| file.respond_to?(:read) }
    return redirect_to grants_tab_path, alert: t(".no_files") if files.empty?

    queued = 0
    rejected = []
    files.each do |file|
      prepared = AccountStatement.prepare_upload!(file)
      statement = AccountStatement.create_from_prepared_upload!(family: Current.family, account: @account, prepared_upload: prepared)
      queued += queue_read(statement)
    rescue AccountStatement::DuplicateUploadError => e
      queued += queue_read(e.statement) if e.statement.account_id == @account.id
    rescue AccountStatement::InvalidUploadError, ActiveRecord::RecordInvalid
      rejected << file.original_filename.to_s
    end

    notice = t(".queued", count: queued)
    notice += " " + t(".rejected", files: rejected.join(", ")) if rejected.any?
    redirect_to grants_tab_path, notice: notice
  end

  # Reads the account's PDF statements that haven't been read for grants yet.
  def read_statements
    statements = @account.account_statements.where(content_type: "application/pdf", equity_grants_read_at: nil)
    queued = statements.sum { |statement| queue_read(statement) }
    redirect_to grants_tab_path, notice: t("equity_grants.upload.queued", count: queued)
  end

  def template
    send_data "grant_id,ticker,grant_type,grant_date,total_units,vest_date,units,units_withheld,net_proceeds\n" \
              "GRANT-001,ACME,rsu,2025-03-01,240,2026-03-15,60,25,\n" \
              "GRANT-001,ACME,rsu,2025-03-01,240,2026-06-15,60,,8500.00\n",
              filename: "equity_grants_template.csv", type: "text/csv"
  end

  private
    def set_writable_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      require_account_permission!(@account)
    end

    def set_grant
      @grant = EquityGrant.where(account_id: Current.user.accessible_accounts.select(:id)).find(params[:id])
      @account = @grant.account
      require_account_permission!(@account)
    end

    def grants_tab_path
      account_path(@account, tab: TAB)
    end

    def queue_read(statement)
      return 0 unless statement.content_type == "application/pdf"

      EquityGrantDocumentReadJob.perform_later(statement, Current.user)
      1
    end

    def grant_params
      params.require(:equity_grant).permit(:grant_identifier, :ticker, :grant_type, :grant_date, :total_units, :strike_price, :notes)
    end
end
