# frozen_string_literal: true

class Api::V1::ImportSessionsController < Api::V1::BaseController
  before_action :ensure_read_scope, only: [ :show ]
  before_action :ensure_write_scope, only: [ :create, :create_chunk, :publish ]
  before_action :set_import_session, only: [ :show, :create_chunk, :publish ]

  def create
    @import_session = ImportSession.create_or_find_for!(
      family: Current.family,
      import_type: params[:type].to_s,
      client_session_id: params[:client_session_id].presence,
      expected_chunks: expected_chunks_param
    )

    render :show, status: :created
  rescue ImportSession::ConflictError => e
    render_import_session_conflict(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Import session could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  def show
    render :show
  end

  def create_chunk
    content, filename, content_type = sure_import_upload_attributes
    return unless content

    @import_session.attach_chunk!(
      sequence: sequence_param,
      client_chunk_id: params[:client_chunk_id].presence,
      content: content,
      filename: filename,
      content_type: content_type
    )

    @import_session.reload
    render :show, status: :created
  rescue ImportSession::ConflictError => e
    render_import_session_conflict(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Import chunk could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  def publish
    @import_session.publish_later
    @import_session.reload
    render :show, status: :accepted
  rescue Import::MaxRowCountExceededError
    render json: {
      error: "max_row_count_exceeded",
      message: "Import session has too many rows to publish."
    }, status: :unprocessable_entity
  rescue ImportSession::ConflictError => e
    render_import_session_conflict(e.message)
  end

  private
    def set_import_session
      @import_session = Current.family.import_sessions.find(params[:id])
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def expected_chunks_param
      return if params[:expected_chunks].blank?

      params[:expected_chunks].to_i
    end

    def sequence_param
      raise ActionController::ParameterMissing.new(:sequence) if params[:sequence].blank?

      params[:sequence].to_i
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
      if file.size > SureImport.max_ndjson_size
        render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
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

      sure_import_validated_attributes(
        content: file.read,
        filename: file.original_filename.presence || "sure-import.ndjson",
        content_type: file.content_type.presence || "application/x-ndjson"
      )
    end

    def sure_import_raw_content_attributes(content)
      if content.bytesize > SureImport.max_ndjson_size
        render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
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

    def render_import_session_conflict(message)
      render json: {
        error: "import_session_conflict",
        message: message
      }, status: :conflict
    end
end
