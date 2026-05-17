# frozen_string_literal: true

class Settings::DebugsController < Admin::BaseController
  FILTER_ID_PARAMS = %i[family_id account_id user_id account_provider_id].freeze

  def show
    filter_params = debug_filters_params

    @start_date = safe_parse_date(filter_params[:start_date])
    @end_date = safe_parse_date(filter_params[:end_date])

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("settings.debugs.show.page_title"), nil ]
    ]

    scope = DebugLogEntry.includes(:family, :account, :user, :account_provider).recent
    scope = scope.with_category(filter_params[:category])
    scope = scope.with_level(filter_params[:level])
    scope = scope.with_source(filter_params[:source])
    scope = scope.with_provider_key(filter_params[:provider_key])

    FILTER_ID_PARAMS.each do |key|
      value = safe_uuid(filter_params[key])
      scope = scope.where(key => value) if value.present?
    end

    scope = scope.where("created_at >= ?", @start_date.beginning_of_day) if @start_date.present?
    scope = scope.where("created_at < ?", @end_date.next_day.beginning_of_day) if @end_date.present?

    @pagy, @debug_log_entries = pagy(scope, limit: safe_per_page(50))
    @categories = DebugLogEntry.distinct.order(:category).pluck(:category)
    @levels = DebugLogEntry::LEVELS
    @sources = DebugLogEntry.distinct.order(:source).pluck(:source)
    @provider_keys = DebugLogEntry.where.not(provider_key: [ nil, "" ]).distinct.order(:provider_key).pluck(:provider_key)
  end

  private
    def safe_parse_date(value)
      Date.iso8601(value)
    rescue ArgumentError, TypeError
      nil
    end

    def safe_uuid(value)
      return if value.blank?

      uuid = value.to_s.strip
      uuid.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i) ? uuid : nil
    end

    def debug_filters_params
      params.permit(:category, :level, :source, :provider_key, :start_date, :end_date, *FILTER_ID_PARAMS)
    end
end
