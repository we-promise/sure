module Localize
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
    around_action :switch_timezone
  end

  private
    def switch_locale(&action)
      locale = locale_from_param || locale_from_user || locale_from_accept_language || locale_from_family || I18n.default_locale
      I18n.with_locale(locale, &action)
    end

    def locale_from_user
      locale = Current.user&.locale
      return if locale.blank?

      locale_sym = locale.to_sym
      locale_sym if I18n.available_locales.include?(locale_sym)
    end

    def locale_from_family
      locale = Current.family&.locale
      return if locale.blank?

      locale_sym = locale.to_sym
      locale_sym if I18n.available_locales.include?(locale_sym)
    end

    def locale_from_accept_language
      locale = accept_language_top_locale
      return if locale.blank?

      locale_sym = locale.to_sym
      return unless I18n.available_locales.include?(locale_sym)

      # Auto-save detected locale to user profile (once per user, not per session)
      if Current.user.present? && Current.user.locale.blank?
        Current.user.update_column(:locale, locale_sym.to_s)
      end

      locale_sym
    end

    def accept_language_top_locale
      header = request.get_header("HTTP_ACCEPT_LANGUAGE")
      return if header.blank?

      # Parse language;q pairs and sort by q-value (descending), preserving header order for ties
      parsed_languages = parse_accept_language(header)
      return if parsed_languages.empty?

      # Find first supported locale by q-value priority
      parsed_languages.each do |lang, _q|
        normalized = normalize_locale(lang)
        canonical = supported_locales[normalized.downcase]
        return canonical if canonical.present?

        primary_language = normalized.split("-").first
        primary_match = supported_locales[primary_language.downcase]
        return primary_match if primary_match.present?
      end

      nil
    end

    def parse_accept_language(header)
      entries = []

      header.split(",").each_with_index do |entry, index|
        parts = entry.split(";")
        language = parts.first.to_s.strip
        next if language.blank?

        # Extract q-value, default to 1.0
        q_value = 1.0
        parts[1..].each do |param|
          param = param.strip
          if param.start_with?("q=")
            q_str = param[2..]
            q_value = Float(q_str) rescue 1.0
            q_value = q_value.clamp(0.0, 1.0)
            break
          end
        end

        entries << [ language, q_value, index ]
      end

      # Sort by q-value descending, then by original header order ascending
      entries.sort_by { |_lang, q, idx| [ -q, idx ] }.map { |lang, q, _idx| [ lang, q ] }
    end

    def supported_locales
      @supported_locales ||= LanguagesHelper::SUPPORTED_LOCALES.each_with_object({}) do |locale, locales|
        normalized = normalize_locale(locale)
        locales[normalized.downcase] = normalized
      end
    end

    def normalize_locale(locale)
      locale.to_s.strip.gsub("_", "-")
    end

    def locale_from_param
      return unless params[:locale].is_a?(String) && params[:locale].present?

      locale = params[:locale].to_sym
      locale if I18n.available_locales.include?(locale)
    end

    def switch_timezone(&action)
      Time.use_zone(resolved_timezone, &action)
    end

    # `Time.use_zone` raises ArgumentError on anything it doesn't recognize,
    # which would otherwise take down every request/render for the affected
    # family -- including the login page, since this runs on every request.
    # Family#resolved_time_zone validates and falls back to the app default
    # instead of crashing; it's also what Sync#perform uses in the background,
    # so a scheduled entry's arrival date agrees with the family's clock in
    # both places.
    def resolved_timezone
      Current.family&.resolved_time_zone || Time.zone
    end
end
