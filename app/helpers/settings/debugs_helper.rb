# frozen_string_literal: true

module Settings::DebugsHelper
  # Maps a DebugLogEntry level onto a DS::Pill semantic tone so severity is
  # scannable at a glance instead of buried in a column of identical text.
  LEVEL_TONES = {
    "debug" => :neutral,
    "info" => :info,
    "warn" => :warning,
    "error" => :error
  }.freeze

  def debug_log_level_tone(level)
    LEVEL_TONES.fetch(level.to_s, :neutral)
  end

  # The context IDs the expanded view lists, in the order support reads them.
  # Returns a label => value hash with blanks already collapsed to the shared
  # "-" placeholder so the template stays declarative.
  def debug_log_context_fields(entry)
    {
      t("settings.debugs.show.details.provider") => entry.provider_key,
      t("settings.debugs.show.details.family_id") => entry.family_id,
      t("settings.debugs.show.details.account_id") => entry.account_id,
      t("settings.debugs.show.details.user_id") => entry.user_id,
      t("settings.debugs.show.details.account_provider_id") => entry.account_provider_id
    }.transform_values { |value| value.presence || t("settings.debugs.show.missing_value") }
  end
end
