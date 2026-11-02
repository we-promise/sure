# frozen_string_literal: true

class Api::V1::VersionsController < Api::V1::BaseController
  prepend_before_action :prevent_version_caching
  skip_before_action :authenticate_request!, if: :public_version_request?
  before_action :ensure_read_scope, unless: :public_version_request?

  def show
    render_json({ version: Sure.version.to_s, commit_sha: Sure.commit_sha.presence })
  end

  private
    def public_version_request?
      Rails.configuration.public_version_endpoint &&
        request.headers["Authorization"].blank? && request.headers["X-Api-Key"].blank?
    end

    def prevent_version_caching
      response.headers["Cache-Control"] = "private, no-store"
    end
end
