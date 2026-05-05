# frozen_string_literal: true

class AccountStatementsController < ApplicationController
  before_action :set_statement, only: %i[show update destroy link unlink reject]
  before_action :ensure_statement_manager!, only: %i[create update destroy link unlink reject]

  def index
    @account_statements = Current.family.account_statements
      .with_attached_original_file
      .includes(:account, :suggested_account)
      .ordered
    @unmatched_statements = @account_statements.unmatched
    @linked_statements = @account_statements.linked
    @total_storage_bytes = @account_statements.sum(:byte_size)
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("account_statements.index.title"), account_statements_path ]
    ]
    render layout: "settings"
  end

  def show
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @reconciliation_checks = @statement.reconciliation_checks
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("account_statements.index.title"), account_statements_path ],
      [ @statement.filename, nil ]
    ]
    render layout: "settings"
  end

  def create
    files = Array(statement_upload_params[:files]).reject(&:blank?).select { |file| file.respond_to?(:read) }
    account = target_account

    if files.empty?
      redirect_back_or_to account_statements_path, alert: t("account_statements.create.no_files")
      return
    end

    return if account && !require_account_permission!(account)

    unless files.all? { |file| valid_upload?(file) }
      redirect_back_or_to redirect_after_create(account), alert: t("account_statements.create.invalid_file_type")
      return
    end

    created = []
    duplicates = []

    files.each do |file|
      created << AccountStatement.create_from_upload!(family: Current.family, account: account, file: file)
    rescue AccountStatement::DuplicateUploadError => e
      duplicates << e.statement
    rescue ActiveRecord::RecordInvalid => e
      redirect_back_or_to redirect_after_create(account), alert: e.record.errors.full_messages.to_sentence
      return
    end

    redirect_to redirect_after_create(account, created.first || duplicates.first),
                flash_for_upload(created:, duplicates:)
  end

  def update
    return if @statement.account && !require_account_permission!(@statement.account)

    target = statement_params[:account_id].present? ? Current.user.accessible_accounts.find(statement_params[:account_id]) : nil
    return if target && !require_account_permission!(target)

    attrs = statement_params.except(:account_id)
    attrs[:account] = target if statement_params.key?(:account_id)

    @statement.assign_attributes(attrs)
    @statement.match_account! if @statement.account.nil? && !@statement.rejected?

    if @statement.save
      redirect_to account_statement_path(@statement), notice: t("account_statements.update.success")
    else
      @accounts = Current.user.accessible_accounts.visible.alphabetically
      @reconciliation_checks = @statement.reconciliation_checks
      flash.now[:alert] = @statement.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity, layout: "settings"
    end
  end

  def link
    account = Current.user.accessible_accounts.find(params[:account_id].presence || @statement.suggested_account_id)
    return unless require_account_permission!(account)

    @statement.link_to_account!(account)
    redirect_to post_link_path(@statement), notice: t("account_statements.link.success", account: account.name)
  end

  def unlink
    return if @statement.account && !require_account_permission!(@statement.account)

    @statement.unlink!
    redirect_to account_statement_path(@statement), notice: t("account_statements.unlink.success")
  end

  def reject
    return if @statement.account && !require_account_permission!(@statement.account)

    @statement.reject_match!
    redirect_to account_statements_path, notice: t("account_statements.reject.success")
  end

  def destroy
    return if @statement.account && !require_account_permission!(@statement.account)

    redirect_path = @statement.account ? account_path(@statement.account, tab: "statements") : account_statements_path
    @statement.destroy
    redirect_to redirect_path, notice: t("account_statements.destroy.success")
  end

  private

    def set_statement
      @statement = Current.family.account_statements
        .with_attached_original_file
        .includes(:account, :suggested_account)
        .find(params[:id])

      raise ActiveRecord::RecordNotFound if @statement.account.present? && !@statement.account.shared_with?(Current.user)
    end

    def ensure_statement_manager!
      return true if Current.user&.admin? || Current.user&.member?

      redirect_to account_statements_path, alert: t("accounts.not_authorized")
      false
    end

    def statement_upload_params
      params.fetch(:account_statement, ActionController::Parameters.new).permit(:account_id, files: [])
    end

    def statement_params
      params.require(:account_statement).permit(
        :account_id,
        :institution_name_hint,
        :account_name_hint,
        :account_last4_hint,
        :period_start_on,
        :period_end_on,
        :opening_balance,
        :closing_balance,
        :currency
      )
    end

    def target_account
      account_id = statement_upload_params[:account_id].presence
      return nil if account_id.blank?

      Current.user.accessible_accounts.find(account_id)
    end

    def valid_upload?(file)
      return false if file.size.to_i > AccountStatement::MAX_FILE_SIZE

      content_type = AccountStatement.detected_content_type(
        content: file.read,
        filename: file.original_filename.to_s,
        declared_content_type: file.content_type
      )
      file.rewind

      return false unless AccountStatement::ALLOWED_CONTENT_TYPES.include?(content_type)
      return valid_pdf?(file) if content_type == "application/pdf"

      true
    end

    def valid_pdf?(file)
      header = file.read(5)
      file.rewind
      header&.start_with?("%PDF-")
    end

    def redirect_after_create(account, statement = nil)
      if account
        account_path(account, tab: "statements")
      elsif statement
        account_statement_path(statement)
      else
        account_statements_path
      end
    end

    def post_link_path(statement)
      statement.account ? account_path(statement.account, tab: "statements") : account_statement_path(statement)
    end

    def flash_for_upload(created:, duplicates:)
      if created.any? && duplicates.any?
        {
          notice: t("account_statements.create.success", count: created.size),
          alert: t("account_statements.create.duplicates", count: duplicates.size)
        }
      elsif created.any?
        { notice: t("account_statements.create.success", count: created.size) }
      else
        { alert: t("account_statements.create.duplicates", count: duplicates.size) }
      end
    end
end
