# frozen_string_literal: true

class BankSyncStatusPresenter
  SNAPSHOT_METHODS = {
    enable_banking: :last_successful_sync_at,
    directa: :portfolio_snapshot_at,
    ca_auto_bank: :snapshot_at,
    scalable: :snapshot_at,
    fineco: :portfolio_snapshot_at
  }.freeze

  attr_reader :item, :provider_key

  def initialize(item:, provider_key:, background_sync_enabled: nil)
    @item = item
    @provider_key = provider_key.to_sym
    @background_sync_enabled = if background_sync_enabled.nil? && @provider_key == :enable_banking
      Setting.auto_sync_enabled?
    else
      background_sync_enabled == true
    end
  end

  def state
    @state ||= if syncing?
      :syncing
    elsif connection_required?
      :connection_required
    elsif reconnect_required?
      :reconnect_required
    elsif rate_limited?
      :rate_limited
    elsif partial_import?
      :partial_import
    elsif temporary_error?
      :temporary_error
    elsif scheduled?
      :scheduled
    elsif last_successful_at.present?
      :up_to_date
    else
      :waiting_for_snapshot
    end
  end

  def title
    I18n.t("bank_sync_status.states.#{state}.title")
  end

  def variant
    case state
    when :up_to_date then :success
    when :temporary_error then expected_retry? ? :warning : :error
    when :rate_limited, :partial_import, :reconnect_required then :warning
    else :info
    end
  end

  def live
    state == :syncing ? :none : :status
  end

  def show_alert?
    !%i[syncing up_to_date].include?(state)
  end

  def icon_name
    state == :syncing ? "loader-circle" : "check-circle"
  end

  def icon_color
    state == :syncing ? "secondary" : "success"
  end

  def message
    key = case state
    when :syncing then "syncing"
    when :up_to_date then "up_to_date"
    when :scheduled then "scheduled"
    when :rate_limited then "rate_limited"
    when :partial_import then "partial_import"
    when :temporary_error then "temporary_error"
    when :reconnect_required then "reconnect_required"
    when :connection_required then "connection_required"
    else "waiting_for_snapshot"
    end

    I18n.t("bank_sync_status.states.#{key}.message", provider: provider_name)
  end

  def timing_message
    messages = []

    if automatic_retry_at.present? && automatic_retry_at > Time.current
      messages << I18n.t("bank_sync_status.timing.automatic_retry", time: format_time(automatic_retry_at))
    elsif automatic_retry_at.present? && retry_pending?
      messages << I18n.t("bank_sync_status.timing.retry_due")
    elsif background_check_at.present? && background_check_at > Time.current
      messages << I18n.t("bank_sync_status.timing.scheduled_background", time: format_time(background_check_at))
    end

    if manual_refresh_at.present? && manual_refresh_at > Time.current
      messages << I18n.t("bank_sync_status.timing.manual_refresh", time: format_time(manual_refresh_at))
    elsif (state == :scheduled || state == :rate_limited) && !manual_refresh_blocked?
      messages << I18n.t("bank_sync_status.timing.manual_refresh_available")
    end

    messages.presence&.join(" ")
  end

  def last_successful_at
    method_name = SNAPSHOT_METHODS.fetch(provider_key)
    return unless item.respond_to?(method_name)

    item.public_send(method_name)
  end

  def last_successful_message
    return I18n.t("bank_sync_status.last_successful.none") unless last_successful_at.present?

    I18n.t("bank_sync_status.last_successful.at", time: format_time(last_successful_at))
  end

  def expected_retry?
    retry_pending? || (state == :rate_limited && cooldown?)
  end

  def retry_pending?
    item.respond_to?(:sync_retry_pending?) && item.sync_retry_pending?
  end

  def terminal_error?
    state == :temporary_error && !expected_retry?
  end

  def needs_attention?
    %i[rate_limited partial_import temporary_error reconnect_required connection_required waiting_for_snapshot].include?(state)
  end

  def manual_refresh_blocked?
    return true if syncing?
    return !item.sync_due? if provider_key == :scalable && item.respond_to?(:sync_due?)
    return cooldown? if item.respond_to?(:sync_cooldown?)

    manual_refresh_at.present? && manual_refresh_at > Time.current
  end

  def summary_status
    return :err if terminal_error?
    return :warn if %i[rate_limited partial_import reconnect_required connection_required waiting_for_snapshot].include?(state)
    return :warn if state == :temporary_error && expected_retry?

    :ok
  end

  def summary_message
    timing_message.presence || message
  end

  def stale_data_message
    return unless %i[rate_limited partial_import temporary_error reconnect_required].include?(state)
    return unless last_successful_at.present?

    I18n.t("bank_sync_status.saved_data_retained")
  end

  def sync_summary_stats(stats)
    return stats unless stats.is_a?(Hash) && expected_defer?

    errors = Array(stats["errors"] || stats[:errors])
    remaining = errors.reject do |error|
      error.is_a?(Hash) && (error["category"] || error[:category]) == "sync_deferred"
    end
    deferred_count = errors.size - remaining.size
    rate_limited_flag = stats["rate_limited"].present? || stats[:rate_limited].present?
    if deferred_count.zero?
      return stats unless rate_limited_flag && errors.empty?

      return stats.merge("total_errors" => 0)
    end

    total_errors = stats["total_errors"] || stats[:total_errors]
    stats.merge(
      "errors" => remaining,
      "total_errors" => [ total_errors.to_i - deferred_count, 0 ].max
    )
  end

  def expected_defer_stats?(stats)
    return false unless stats.is_a?(Hash) && expected_defer?
    return true if stats["rate_limited"].present? || stats[:rate_limited].present?

    errors = Array(stats["errors"] || stats[:errors])
    errors.any? do |error|
      error.is_a?(Hash) && (error["category"] || error[:category]) == "sync_deferred"
    end
  end

  def expected_defer?
    state == :rate_limited || (state == :temporary_error && retry_pending?)
  end

  private

    def syncing?
      item.respond_to?(:syncing?) && item.syncing?
    end

    def reconnect_required?
      if provider_key == :enable_banking
        item.respond_to?(:requires_update?) && item.requires_update? ||
          (item.respond_to?(:session_id) && item.session_id.present? && item.respond_to?(:session_valid?) && !item.session_valid?)
      else
        item.respond_to?(:requires_update?) && item.requires_update?
      end
    end

    def connection_required?
      if provider_key == :enable_banking
        return false if item.respond_to?(:requires_update?) && item.requires_update?
        return item.respond_to?(:session_id) && item.session_id.blank? &&
          item.respond_to?(:credentials_configured?) && item.credentials_configured? &&
          !last_successful_at.present? && !authentication_error?
      end

      return false if fineco_previously_authorized?
      return false unless item.respond_to?(:session_configured?)
      return false if item.session_configured?
      return false if item.respond_to?(:session_id) && item.session_id.present?
      return false if authentication_error?
      return true unless last_successful_at.present?

      false
    end

    def fineco_previously_authorized?
      return false unless provider_key == :fineco
      return false unless item.respond_to?(:requires_update?) && item.requires_update?

      %i[bank_account_number dossier_identity].all? do |attribute|
        item.respond_to?(attribute) && item.public_send(attribute).present?
      end
    end

    def authentication_error?
      item.respond_to?(:last_sync_error_code) &&
        %w[authentication_failed invalid_session session_expired].include?(item.last_sync_error_code)
    end

    def rate_limited?
      if provider_key == :enable_banking
        (item.respond_to?(:sync_retry_reason) && item.sync_retry_reason == "rate_limited") ||
          (item.respond_to?(:sync_rate_limited?) && item.sync_rate_limited?)
      else
        (item.respond_to?(:last_sync_error_code) && item.last_sync_error_code == "rate_limited") ||
          (item.respond_to?(:history_sync_error_code) && item.history_sync_error_code == "history_rate_limited") ||
          (item.respond_to?(:sync_rate_limited?) && item.sync_rate_limited?)
      end
    end

    def temporary_error?
      return false if awaiting_valuation?
      return true if provider_key == :enable_banking && item.respond_to?(:sync_retry_reason) && item.sync_retry_reason == "temporary_error"
      return true if item.respond_to?(:last_sync_error_code) && item.last_sync_error_code.present?
      return true if item.respond_to?(:last_history_sync_error) && item.last_history_sync_error.present?
      return true if item.respond_to?(:sync_error) && item.sync_error.present?
      return true if provider_key == :enable_banking && latest_sync_failed?
      return true if item.respond_to?(:error_message) && item.error_message.present?

      false
    end

    def awaiting_valuation?
      provider_key == :directa && item.respond_to?(:last_sync_error_code) &&
        item.last_sync_error_code == "awaiting_valuation"
    end

    def latest_sync_failed?
      return false unless item.respond_to?(:latest_sync_record)

      latest_sync = item.latest_sync_record
      latest_sync&.failed? || latest_sync&.stale?
    end

    def partial_import?
      return false unless provider_key == :enable_banking && item.respond_to?(:latest_sync_record)

      stats = item.latest_sync_record&.sync_stats
      stats.is_a?(Hash) && (stats["partial_import"] || stats[:partial_import]).present?
    end

    def scheduled?
      (automatic_retry_at.present? && automatic_retry_at > Time.current) ||
        (background_check_at.present? && background_check_at > Time.current) ||
        (manual_refresh_at.present? && manual_refresh_at > Time.current)
    end

    def cooldown?
      item.respond_to?(:sync_cooldown?) && item.sync_cooldown?
    end

    def automatic_retry_at
      return unless provider_key == :enable_banking
      return unless item.respond_to?(:sync_retry_at)
      return unless retry_pending?
      return unless enable_banking_session_valid?
      return unless %w[rate_limited temporary_error].include?(item.try(:sync_retry_reason).to_s)

      item.sync_retry_at
    end

    def background_check_at
      return unless provider_key == :enable_banking && @background_sync_enabled
      return unless item.respond_to?(:next_background_sync_at)
      return unless enable_banking_session_valid?

      background_at = item.next_background_sync_at
      return unless background_at.present?

      [ background_at, item.try(:sync_eligible_at), item.try(:sync_rate_limited_until) ].compact.max
    end

    def enable_banking_session_valid?
      return false unless provider_key == :enable_banking
      return false unless item.respond_to?(:session_valid?) && item.session_valid?
      return false if item.respond_to?(:needs_authorization?) && item.needs_authorization?
      return false if reconnect_required? || connection_required?

      true
    end

    def manual_refresh_at
      if item.respond_to?(:sync_eligible_at)
        item.sync_eligible_at
      elsif provider_key == :scalable && item.respond_to?(:next_sync_at)
        item.next_sync_at
      end
    end

    def provider_name
      case provider_key
      when :enable_banking
        item.try(:institution_display_name).presence || I18n.t("bank_sync_status.providers.enable_banking")
      else
        I18n.t("bank_sync_status.providers.#{provider_key}")
      end
    end

    def format_time(value)
      zone = Time.zone || Time.zone_default || ActiveSupport::TimeZone["UTC"]
      local_time = value.in_time_zone(zone)
      I18n.t("bank_sync_status.time_with_zone", time: I18n.l(local_time, format: :long), time_zone: zone.name)
    end
end
