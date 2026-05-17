# frozen_string_literal: true

class Api::V1::BankdataImportsController < Api::V1::BaseController
  before_action -> { authorize_scope!(:write) }

  def preview
    summary = run_import(:preview)
    render json: summary.as_json, status: :ok
  rescue BankdataImport::ValidationError => error
    render_json({ error: "validation_failed", message: error.message, errors: error.errors }, status: :unprocessable_entity)
  end

  def create
    summary = run_import(:import)
    render json: summary.as_json, status: :created
  rescue BankdataImport::ValidationError => error
    render_json({ error: "validation_failed", message: error.message, errors: error.errors }, status: :unprocessable_entity)
  end

  private
    def run_import(mode)
      BankdataImport::AppendOnlyImporter.new(
        family: current_resource_owner.family,
        payload: request_payload,
        mode: mode
      ).call
    end

    def request_payload
      JSON.parse(request.raw_post.presence || "{}")
    end
end
