# frozen_string_literal: true

module SafePagination
  extend ActiveSupport::Concern

  private
    def safe_per_page(default = 10)
      allowed_values = User::TRANSACTIONS_PER_PAGE_OPTIONS
      default = default.to_i
      default = 10 unless allowed_values.include?(default)

      per_page = params[:per_page].to_i

      return default if per_page <= 0

      allowed_values.include?(per_page) ? per_page : allowed_values.min_by { |v| (v - per_page).abs }
    end
end
