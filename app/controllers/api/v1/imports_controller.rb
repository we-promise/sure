# frozen_string_literal: true

class Api::V1::ImportsController < Api::V1::BaseController
  include Pagy::Backend

  # Ensure proper scope authorization
  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :set_import, only: [ :show ]

  def index
    family = current_resource_owner.family
    imports_query = family.imports.ordered

    # Apply filters
    if params[:status].present?
      imports_query = imports_query.where(status: params[:status])
    end

    if params[:type].present?
      imports_query = imports_query.where(type: params[:type])
    end

    # Pagination
    @pagy, @imports = pagy(
      imports_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index

  rescue => e
    Rails.logger.error "ImportsController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  def show
    render :show
  rescue => e
    Rails.logger.error "ImportsController#show error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # 1. Build the import object
    @import = family.imports.build(import_params)
    @import.type = "TransactionImport" # Default to transaction import for now

    # 2. Attach the uploaded file if present (assuming raw_file_str for now or ActiveStorage)
    # The Import model uses `raw_file_str` to store the content directly or we can handle file upload
    if params[:file].present?
      @import.raw_file_str = params[:file].read
    elsif params[:raw_file_content].present?
      @import.raw_file_str = params[:raw_file_content]
    end

    # 3. Save and Process
    if @import.save
      # Generate rows if file content was provided
      if @import.uploaded?
        begin
          @import.generate_rows_from_csv
          @import.reload
        rescue => e
          Rails.logger.error "Row generation failed for import #{@import.id}: #{e.message}"
        end
      end

      # If the import is configured (has rows), we can try to auto-publish or just leave it as pending
      # For API simplicity, if enough info is provided, we might want to trigger processing

      if @import.configured? && params[:publish] == "true"
        @import.publish_later
      end

      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Import could not be created",
        errors: @import.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue => e
    Rails.logger.error "ImportsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  private

    def set_import
      @import = current_resource_owner.family.imports.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Import not found" }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def import_params
      params.permit(
        :account_id,
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :notes_col_label,
        :account_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :col_sep
      )
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).include?(per_page) ? per_page : 25
    end
end
