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

    render_import_session(status: :created)
  rescue ImportSession::ConflictError => e
    render_import_session_conflict(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(
      "validation_failed",
      "Import session could not be created",
      :unprocessable_entity,
      errors: e.record.errors.full_messages
    )
  end

  def show
    render_import_session
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
    render_import_session(status: :created)
  rescue ImportSession::ConflictError => e
    render_import_session_conflict(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_error(
      "validation_failed",
      "Import chunk could not be created",
      :unprocessable_entity,
      errors: e.record.errors.full_messages
    )
  end

  def publish
    @import_session.publish_later
    @import_session.reload
    render_import_session(status: :accepted)
  rescue Import::MaxRowCountExceededError
    render_error("max_row_count_exceeded", "Import session has too many rows to publish.", :unprocessable_entity)
  rescue ImportSession::EnqueueError
    render_error("import_enqueue_failed", "Import session could not be queued.", :service_unavailable)
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

      params[:expected_chunks]
    end

    def sequence_param
      raise ActionController::ParameterMissing.new(:sequence) if params[:sequence].blank?

      params[:sequence]
    end

    def sure_import_upload_attributes
      if params[:file].present?
        sure_import_file_upload_attributes(params[:file])
      elsif params[:raw_file_content].present?
        sure_import_raw_content_attributes(params[:raw_file_content].to_s)
      else
        render_error("missing_content", "Provide a Sure NDJSON file or raw_file_content.", :unprocessable_entity)
        nil
      end
    end

    def sure_import_file_upload_attributes(file)
      if file.size > SureImport.max_ndjson_size
        render_error(
          "file_too_large",
          "File is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB.",
          :unprocessable_entity
        )
        return
      end

      extension = File.extname(file.original_filename.to_s).downcase
      unless SureImport::ALLOWED_NDJSON_CONTENT_TYPES.include?(file.content_type) || extension.in?(%w[.ndjson .json])
        render_error("invalid_file_type", "Invalid file type. Please upload a Sure NDJSON file.", :unprocessable_entity)
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
        render_error(
          "content_too_large",
          "Content is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB.",
          :unprocessable_entity
        )
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
        render_error("invalid_ndjson", "Invalid Sure NDJSON content.", :unprocessable_entity)
        return
      end

      [ content, filename, content_type ]
    end

    def render_import_session_conflict(message)
      render_error("import_session_conflict", message, :conflict)
    end

    def render_import_session(status: :ok)
      chunks = @import_session.imports.ordered_by_sequence.map do |import|
        {
          id: import.id,
          sequence: import.sequence,
          client_chunk_id: import.client_chunk_id,
          status: import.status,
          rows_count: import.rows_count,
          summary: import.summary || {},
          error: import.error_details.presence,
          created_at: import.created_at,
          updated_at: import.updated_at
        }
      end

      render json: {
        data: {
          id: @import_session.id,
          type: @import_session.import_type,
          status: @import_session.status,
          client_session_id: @import_session.client_session_id,
          expected_chunks: @import_session.expected_chunks,
          chunks_count: chunks.size,
          summary: @import_session.summary || {},
          error: @import_session.error_details.presence,
          created_at: @import_session.created_at,
          updated_at: @import_session.updated_at,
          chunks: chunks
        }
      }, status: status
    end

    def render_error(error, message, status, errors: nil)
      payload = { error: error, message: message }
      payload[:errors] = errors if errors
      render json: payload, status: status
    end
end
