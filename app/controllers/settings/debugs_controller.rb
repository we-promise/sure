# frozen_string_literal: true

class Settings::DebugsController < Admin::BaseController

  def show
    @start_date = safe_parse_date(params[:start_date])
    @end_date = safe_parse_date(params[:end_date])

    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Debug", nil ]
    ]

    scope = DebugLogEntry.includes(:family, :account, :user, :account_provider).recent
    scope = scope.with_category(params[:category])
    scope = scope.with_level(params[:level])
    scope = scope.with_source(params[:source])
    scope = scope.with_provider_key(params[:provider_key])
    scope = scope.where(family_id: params[:family_id]) if params[:family_id].present?
    scope = scope.where(account_id: params[:account_id]) if params[:account_id].present?
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    scope = scope.where(account_provider_id: params[:account_provider_id]) if params[:account_provider_id].present?
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
end
