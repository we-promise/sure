# frozen_string_literal: true

module Api::V1::SecurityResourceFiltering
  class InvalidFilterError < StandardError; end

  BOOLEAN_FILTERS = {
    "true" => true,
    "1" => true,
    "false" => false,
    "0" => false
  }.freeze

  private

    def scoped_security_ids
      Security
        .where(id: holding_security_ids)
        .or(Security.where(id: trade_security_ids))
        .distinct
        .select(:id)
    end

    def holding_security_ids
      Holding.where(account_id: accessible_account_ids).select(:security_id)
    end

    def trade_security_ids
      Trade.joins(:entry).where(entries: { account_id: accessible_account_ids }).select(:security_id)
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts.visible.accessible_by(current_resource_owner).select(:id)
    end

    def parse_boolean_filter_param(key)
      normalized_value = params[key].to_s.strip.downcase

      invalid_filter!("#{key} must be true or false") if normalized_value.blank?
      return BOOLEAN_FILTERS.fetch(normalized_value) if BOOLEAN_FILTERS.key?(normalized_value)

      invalid_filter!("#{key} must be true or false")
    end

    def parse_date_param(key)
      Date.iso8601(params[key].to_s)
    rescue ArgumentError
      invalid_filter!("#{key} must be an ISO 8601 date")
    end

    def invalid_filter!(message)
      raise InvalidFilterError, message
    end
end
