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
      locale_sym if I18n.available_locales.include?(locale_sym)
    end

    def accept_language_top_locale
      header = request.get_header("HTTP_ACCEPT_LANGUAGE")
      return if header.blank?

      top_language = header.split(",").first.to_s.split(";").first.to_s.strip
      return if top_language.blank?

      normalized = normalize_locale(top_language)
      canonical = supported_locales[normalized.downcase]
      return canonical if canonical.present?

      primary_language = normalized.split("-").first
      supported_locales[primary_language.downcase]
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
      timezone = Current.family.try(:timezone) || Time.zone
      Time.use_zone(timezone, &action)
    end
end
