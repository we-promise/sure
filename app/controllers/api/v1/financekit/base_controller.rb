class Api::V1::Financekit::BaseController < Api::V1::BaseController
  wrap_parameters false

  before_action :require_financekit_access
  rescue_from Financekit::Error, with: :protocol_error
  rescue_from ActiveRecord::RecordInvalid, with: :invalid_record
  rescue_from ActiveRecord::RecordNotUnique, with: :duplicate_record
  rescue_from KeyError, with: :invalid_record

  private

    # Publishing is admin-only, as connecting any provider is: it writes into
    # accounts the whole family reads. Nothing else gates it -- there is no
    # server-side feature flag, and no per-user preview opt-in. Whether a build
    # offers Wallet sync at all is the iOS client's decision, made through
    # StoreKit, which the server has no way to check and does not try to.
    def require_financekit_access
      return unless authorize_scope!(request.get? || request.head? ? :read : :write)
      raise Financekit::Error.new("publisher_forbidden", 403) unless current_resource_owner.admin?
    end

    def connection
      @connection ||= current_resource_owner.family.financekit_items.where(user: current_resource_owner).find(params[:connection_id] || params[:id])
    end

    def input
      request.request_parameters
    end

    def protocol_error(error)
      response.headers["Retry-After"] = "60" if [ 429, 503 ].include?(error.status)
      render_json({ error: error.code }, status: error.status)
    end

    def invalid_record(_error)
      protocol_error(Financekit::Error.new("validation_failed"))
    end

    def duplicate_record(_error)
      protocol_error(Financekit::Error.new("resource_conflict", 409))
    end
end
