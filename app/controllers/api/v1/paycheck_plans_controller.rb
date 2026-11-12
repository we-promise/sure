# frozen_string_literal: true

# Paycheck Flow Planner (M2): the family's resolved money map for one month —
# which income series funds which account at which mode, the per-paycheck
# amounts, per-partner leftover attribution, the fun-money delta with its
# suggested percent shift, and the shortfall flags. Read-only; powers the flow
# page later and mobile even later.
class Api::V1::PaycheckPlansController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    family = family_for_request
    return unless family

    month = params[:month].nil? ? Date.current.beginning_of_month : parse_month(params[:month])
    return invalid_query("invalid_month", "month must be a YYYY-MM month") if month.nil?

    render json: PaycheckFlowPlanner.for_family(family: family, month: month)
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    # 404 on a malformed id, 403 when the caller is not a member of this family.
    # Note: ensure_current_family_access is for sub-resources carrying a
    # family_id; a Family itself has none, so compare ids directly.
    def family_for_request
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      family = Family.find(params[:id])
      unless family.id == current_resource_owner&.family_id
        Rails.logger.warn "API Forbidden: User #{current_resource_owner&.email} attempted to access family #{family.id}"
        render_json({ error: "forbidden", message: "Access denied to this resource" }, status: :forbidden)
        return nil
      end

      family
    end

    # Strict YYYY-MM. Future months are legitimate planning targets here,
    # unlike the backward-looking cash flow endpoint.
    def parse_month(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)

      Date.new(value[0, 4].to_i, value[5, 2].to_i, 1)
    rescue Date::Error
      nil
    end

    def invalid_query(error, message)
      render json: { error: error, message: message }, status: :unprocessable_entity
    end
end
