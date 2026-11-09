# frozen_string_literal: true

class Api::V1::AccountStatementsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :ensure_statement_manager
  before_action :set_statement, only: [ :show ]

  def index
    # Mirrors AccountStatement#viewable_by? for a statement manager in SQL, so
    # pages are never underfilled: unlinked statements are visible, linked ones
    # follow the account.
    statements = family.account_statements
      .where(account_id: nil)
      .or(family.account_statements.where(account_id: current_resource_owner.accessible_accounts.select(:id)))
      .includes(:account, :suggested_account)
      .ordered

    statements = apply_filters(statements)
    @per_page = safe_per_page_param
    @pagy, @statements = pagy(statements, page: safe_page_param, limit: @per_page)

    render :index
  end

  def show
    render :show
  end

  def create
    file = params[:file]
    unless file.respond_to?(:read) && file.respond_to?(:original_filename)
      render_validation_error("file is required (multipart/form-data)")
      return
    end

    account = target_account
    return if performed?

    prepared_upload = AccountStatement.prepare_upload!(file)
    @statement = AccountStatement.create_from_prepared_upload!(
      family: family,
      account: account,
      prepared_upload: prepared_upload
    )

    render :show, status: :created
  rescue AccountStatement::DuplicateUploadError => e
    render_duplicate(e.statement)
  rescue AccountStatement::InvalidUploadError
    render_validation_error(
      "file must be a readable #{AccountStatement::ACCEPTED_FILE_EXTENSIONS.join(", ")} document whose contents match its extension, " \
      "at most #{AccountStatement::MAX_FILE_SIZE / 1.megabyte} MB"
    )
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Statement could not be stored",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  private

    def family
      current_resource_owner.family
    end

    def set_statement
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @statement = family.account_statements
        .includes(:account, :suggested_account)
        .find(params[:id])

      raise ActiveRecord::RecordNotFound unless @statement.viewable_by?(current_resource_owner)
    end

    # Uploading links the statement straight away, so it needs the same write
    # access to the account as the web upload form.
    def target_account
      account_id = params[:account_id].presence
      return nil if account_id.blank?

      account = family.accounts.writable_by(current_resource_owner).find_by(id: account_id) if valid_uuid?(account_id)
      return account if account

      render json: {
        error: "not_found",
        message: "No account you can write to matched account_id. Omit account_id to upload the statement unlinked."
      }, status: :not_found
      nil
    end

    # The existing copy may be filed against an account this user cannot see,
    # so its details are only returned when it is visible to them.
    def render_duplicate(statement)
      if statement.viewable_by?(current_resource_owner)
        @statement = statement
        @duplicate = true
        render :show, status: :ok
      else
        render json: {
          error: "duplicate",
          message: "This file is already in the Statement Vault"
        }, status: :conflict
      end
    end

    def apply_filters(scope)
      if params[:account_id].present?
        raise InvalidFilterError, "account_id must be a valid UUID" unless valid_uuid?(params[:account_id])

        scope = scope.where(account_id: params[:account_id])
      end

      if params[:review_status].present?
        unless AccountStatement.review_statuses.key?(params[:review_status].to_s)
          raise InvalidFilterError, "review_status must be one of: #{AccountStatement.review_statuses.keys.join(", ")}"
        end

        scope = scope.where(review_status: params[:review_status].to_s)
      end

      # The column only holds lowercase hex.
      scope = scope.where(content_sha256: params[:content_sha256].to_s.strip.downcase) if params[:content_sha256].present?
      scope = scope.where("period_end_on >= ?", parse_date_param(:start_date)) if params[:start_date].present?
      scope = scope.where("period_start_on <= ?", parse_date_param(:end_date)) if params[:end_date].present?
      scope
    end

    def ensure_statement_manager
      return if AccountStatement.statement_manager?(current_resource_owner)

      render json: {
        error: "forbidden",
        message: "The Statement Vault requires an admin or member role"
      }, status: :forbidden
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end
end
