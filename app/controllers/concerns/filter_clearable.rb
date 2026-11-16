module FilterClearable
  extend ActiveSupport::Concern

  private
    def without_cleared_filter(q_params)
      param_key = params[:param_key]

      if q_params[param_key].is_a?(Array)
        q_params[param_key].delete(params[:param_value])
        q_params.delete(param_key) if q_params[param_key].empty?
      else
        q_params.delete(param_key)
      end

      q_params.delete("amount_operator") unless q_params["amount"].present?
      q_params.presence
    end
end
