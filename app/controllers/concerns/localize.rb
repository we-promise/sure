module Localize
  extend ActiveSupport::Concern

  included do
    around_action :switch_locale
    around_action :switch_timezone
  end

  private
    def switch_locale(&action)
      locale = Current.family.try(:locale) || preferred_locale_from_accept_language || I18n.default_locale
      I18n.with_locale(locale, &action)
    end

    def switch_timezone(&action)
      timezone = Current.family.try(:timezone) || Time.zone
      Time.use_zone(timezone, &action)
    end

    def preferred_locale_from_accept_language
      header = request.env["HTTP_ACCEPT_LANGUAGE"].to_s
      return if header.blank?

      accepted_locales = header.split(",").map { |part| part.split(";").first.to_s.strip }
      return if accepted_locales.empty?

      available_locales = I18n.available_locales.map(&:to_s)
      accepted_locales.each do |accepted_locale|
        next if accepted_locale.blank?

        direct_match = available_locales.find { |available| available.casecmp(accepted_locale).zero? }
        return direct_match if direct_match

        primary = accepted_locale.split("-").first
        primary_match = available_locales.find { |available| available.casecmp(primary).zero? }
        return primary_match if primary_match
      end

      nil
    end
end
