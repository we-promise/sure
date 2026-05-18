# frozen_string_literal: true

class AccountStatementsController < ApplicationController
  before_action :set_statement, only: %i[show update destroy link unlink reject]
  before_action :ensure_statement_manager!, only: %i[index create update destroy link unlink reject]

  def index
    accessible_account_ids = Current.user.accessible_accounts.select(:id)
    account_statements = Current.family.account_statements
      .with_attached_original_file
      .includes(:account, :suggested_account)
      .ordered
    visible_storage_scope = Current.family.account_statements
      .where(account_id: nil)
      .or(Current.family.account_statements.where(account_id: accessible_account_ids))
    linked_statement_scope = account_statements.with_account.where(account_id: accessible_account_ids)

    @unmatched_pagy, @unmatched_statements = pagy(account_statements.unmatched, limit: safe_per_page, page_param: :unmatched_page)
    @linked_pagy, @linked_statements = pagy(linked_statement_scope, limit: safe_per_page, page_param: :linked_page)
    @total_storage_bytes = visible_storage_scope.sum(:byte_size)
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("account_statements.index.title"), account_statements_path ]
    ]
    render layout: "settings"
  end

  def show
    @accounts = Current.user.accessible_accounts.visible.alphabetically
    @can_manage_statement = @statement.manageable_by?(Current.user)
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

    created = []
    duplicates = []
    validation_errors = []

    files.each do |file|
      prepared_upload = AccountStatement.prepare_upload!(file)
      created << AccountStatement.create_from_prepared_upload!(family: Current.family, account: account, prepared_upload: prepared_upload)
    rescue AccountStatement::InvalidUploadError
      validation_errors << t("account_statements.create.invalid_file_type")
    rescue AccountStatement::DuplicateUploadError => e
      duplicates << e.statement
    rescue ActiveRecord::RecordInvalid => e
      validation_errors << e.record.errors.full_messages.to_sentence
    end

    redirect_to redirect_after_create(account, created.first || duplicates.first),
                flash_for_upload(created:, duplicates:, validation_errors:)
  end

  def update
    return if @statement.account && !require_account_permission!(@statement.account)

    target = statement_account_id.present? ? Current.user.accessible_accounts.find(statement_account_id) : nil
    return if target && !require_account_permission!(target)

    attrs = statement_params.to_h
    attrs[:account] = target if statement_account_id_provided?

    @statement.assign_attributes(attrs)
    @statement.assign_account_match if @statement.account.nil? && !@statement.rejected?

    if @statement.save
      redirect_to account_statement_path(@statement), notice: t("account_statements.update.success")
    else
      @accounts = Current.user.accessible_accounts.visible.alphabetically
      @can_manage_statement = @statement.manageable_by?(Current.user)
      @reconciliation_checks = @statement.reconciliation_checks
      flash.now[:alert] = @statement.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity, layout: "settings"
    end
  end

  def link
    return if @statement.account && !require_account_permission!(@statement.account)

    account_id = params[:account_id].presence || @statement.suggested_account_id
    if account_id.blank?
      redirect_to account_statement_path(@statement), alert: t("account_statements.link.no_account")
      return
    end

    account = Current.user.accessible_accounts.find(account_id)
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
    if @statement.destroy
      redirect_to redirect_path, notice: t("account_statements.destroy.success")
    else
      redirect_back_or_to redirect_path, alert: t("account_statements.destroy.failure")
    end
  end

  private

    def set_statement
      @statement = Current.family.account_statements
        .with_attached_original_file
        .includes(:account, :suggested_account)
        .find(params[:id])

      raise ActiveRecord::RecordNotFound unless @statement.viewable_by?(Current.user)
    end

    def ensure_statement_manager!
      return if AccountStatement.statement_manager?(Current.user)

      redirect_to accounts_path, alert: t("accounts.not_authorized")
    end

    def statement_upload_params
      params.fetch(:account_statement, ActionController::Parameters.new).permit(files: [])
    end

    def statement_params
      params.require(:account_statement).permit(
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
      account_id = statement_account_id.presence
      return nil if account_id.blank?

      Current.user.accessible_accounts.find(account_id)
    end

    def statement_account_id
      params.fetch(:account_statement, ActionController::Parameters.new)[:account_id]
    end

    def statement_account_id_provided?
      params.fetch(:account_statement, ActionController::Parameters.new).key?(:account_id)
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

    def flash_for_upload(created:, duplicates:, validation_errors: [])
      alerts = []
      alerts << t("account_statements.create.duplicates", count: duplicates.size) if duplicates.any?
      alerts.concat(validation_errors.compact_blank)

      if created.any?
        flash = { notice: t("account_statements.create.success", count: created.size) }
        flash[:alert] = alerts.to_sentence if alerts.any?
        flash
      else
        { alert: alerts.to_sentence }
      end
    end
end
