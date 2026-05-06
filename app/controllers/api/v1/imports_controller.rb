# frozen_string_literal: true

class Api::V1::ImportsController < Api::V1::BaseController
  include Pagy::Backend

  # Ensure proper scope authorization
  before_action :ensure_read_scope, only: [ :index, :show, :rows ]
  before_action :ensure_write_scope, only: [ :create ]
  before_action :set_import_with_rows, only: [ :show ]
  before_action :set_import, only: [ :rows ]

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

  rescue StandardError => e
    Rails.logger.error "ImportsController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  def show
    render :show
  rescue StandardError => e
    Rails.logger.error "ImportsController#show error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  def rows
    @per_page = safe_per_page_param
    @pagy, @rows = pagy(
      @import.rows_ordered,
      page: safe_page_param,
      limit: @per_page
    )
    @rows.each(&:valid?)
    @row_mapping_lookup = @import.mappings.includes(:mappable).index_by { |mapping| [ mapping.type, mapping.key.to_s ] }

    render :rows
  rescue StandardError => e
    Rails.logger.error "ImportsController#rows error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # 1. Determine type and validate
    type = params[:type].to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)
    return create_sure_import(family) if type == "SureImport"

    # 2. Build the import object with permitted config attributes
    @import = family.imports.build(import_config_params.merge(type: type))
    @import.account_id = params[:account_id] if params[:account_id].present?

    # 3. Attach the uploaded file if present (with validation)
    if params[:file].present?
      file = params[:file]

      if file.size > Import::MAX_CSV_SIZE
        return render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import::MAX_CSV_SIZE / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        return render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a CSV file."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = file.read
    elsif params[:raw_file_content].present?
      if params[:raw_file_content].bytesize > Import::MAX_CSV_SIZE
        return render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{Import::MAX_CSV_SIZE / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = params[:raw_file_content]
    end

    # 4. Save and Process
    if @import.save
      # Generate rows if file content was provided
      if @import.uploaded?
        begin
          @import.generate_rows_from_csv
          @import.reload
        rescue StandardError => e
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

  rescue StandardError => e
    Rails.logger.error "ImportsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: e.message }, status: :internal_server_error
  end

  private

    def set_import
      @import = import_scope.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def set_import_with_rows
      @import = import_scope.includes(:rows).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def import_scope
      current_resource_owner.family.imports
    end

    def render_import_not_found
      render json: { error: "not_found", message: "Import not found" }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def import_config_params
      params.permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :notes_col_label,
        :external_id_col_label,
        :account_col_label,
        :qty_col_label,
        :ticker_col_label,
        :price_col_label,
        :entity_type_col_label,
        :currency_col_label,
        :exchange_operating_mic_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :col_sep,
        :amount_type_strategy,
        :amount_type_inflow_value
      )
    end

    def create_sure_import(family)
      content, filename, content_type = sure_import_upload_attributes
      return unless content

      begin
        @import = persist_sure_import!(family, content, filename, content_type)
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          error: "validation_failed",
          message: "Import could not be created",
          errors: e.record&.errors&.full_messages || @import&.errors&.full_messages || []
        }, status: :unprocessable_entity
        return
      rescue StandardError => e
        Rails.logger.error "Sure import creation failed: #{e.message}"
        render json: {
          error: "internal_server_error",
          message: "Import could not be created"
        }, status: :internal_server_error
        return
      end

      begin
        @import.publish_later if @import.publishable? && params[:publish] == "true"
      rescue Import::MaxRowCountExceededError
        render json: {
          error: "max_row_count_exceeded",
          message: "Import was uploaded but has too many rows to publish automatically.",
          import_id: @import.id
        }, status: :unprocessable_entity
        return
      rescue StandardError => e
        Rails.logger.error "Sure import publish failed for import #{@import.id}: #{e.message}"
        restore_pending_sure_import_after_publish_failure
        render json: {
          error: "publish_failed",
          message: "Import was uploaded but could not be queued for processing.",
          import_id: @import.id
        }, status: :internal_server_error
        return
      end

      render :show, status: :created
    end

    def persist_sure_import!(family, content, filename, content_type)
      import = nil
      import = family.imports.create!(type: "SureImport")
      import.ndjson_file.attach(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type
      )
      import.sync_ndjson_rows_count!
      import
    rescue StandardError => e
      clean_up_failed_sure_import(import)
      raise
    end

    def restore_pending_sure_import_after_publish_failure
      # Import#publish_later flips status to importing before enqueueing the job.
      @import.update_column(:status, "pending") if @import&.persisted? && @import.importing?
    end

    def clean_up_failed_sure_import(import)
      return unless import

      begin
        import.ndjson_file.purge if import.ndjson_file.attached?
      rescue StandardError => e
        Rails.logger.warn "Failed to purge Sure import attachment #{import.id}: #{e.message}"
      ensure
        import.destroy if import.persisted?
      end
    end

    def sure_import_upload_attributes
      if params[:file].present?
        sure_import_file_upload_attributes(params[:file])
      elsif params[:raw_file_content].present?
        sure_import_raw_content_attributes(params[:raw_file_content].to_s)
      else
        render json: {
          error: "missing_content",
          message: "Provide a Sure NDJSON file or raw_file_content."
        }, status: :unprocessable_entity
        nil
      end
    end

    def sure_import_file_upload_attributes(file)
      if file.size > SureImport::MAX_NDJSON_SIZE
        render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{SureImport::MAX_NDJSON_SIZE / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      extension = File.extname(file.original_filename.to_s).downcase
      unless SureImport::ALLOWED_NDJSON_CONTENT_TYPES.include?(file.content_type) || extension.in?(%w[.ndjson .json])
        render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a Sure NDJSON file."
        }, status: :unprocessable_entity
        return
      end

      content = file.read
      sure_import_validated_attributes(
        content: content,
        filename: file.original_filename.presence || "sure-import.ndjson",
        content_type: file.content_type.presence || "application/x-ndjson"
      )
    end

    def sure_import_raw_content_attributes(content)
      if content.bytesize > SureImport::MAX_NDJSON_SIZE
        render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{SureImport::MAX_NDJSON_SIZE / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      sure_import_validated_attributes(
        content: content,
        filename: "sure-import.ndjson",
        content_type: "application/x-ndjson"
      )
    end

    def sure_import_validated_attributes(content:, filename:, content_type:)
      unless SureImport.valid_ndjson_first_line?(content)
        render json: {
          error: "invalid_ndjson",
          message: "Invalid Sure NDJSON content."
        }, status: :unprocessable_entity
        return
      end

      [ content, filename, content_type ]
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
