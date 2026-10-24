# frozen_string_literal: true

module GocardlessAccount::DataHelpers
  extend ActiveSupport::Concern

  private

    # Convert SDK objects to hashes via JSON round-trip
    # Many SDKs return objects that don't have proper #to_h methods
    def sdk_object_to_hash(obj)
      return obj if obj.is_a?(Hash)

      if obj.respond_to?(:to_json)
        JSON.parse(obj.to_json)
      elsif obj.respond_to?(:to_h)
        obj.to_h
      else
        obj
      end
    rescue JSON::ParserError, TypeError
      obj.respond_to?(:to_h) ? obj.to_h : {}
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("GocardlessAccount::DataHelpers - Failed to parse decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(date_value, family: nil)
      return nil if date_value.nil?

      tz = family&.timezone

      case date_value
      when String
        if tz && (date_value.include?("T") || date_value.include?(":"))
          Time.parse(date_value).in_time_zone(tz).to_date
        else
          Date.parse(date_value)
        end
      when Time, DateTime, ActiveSupport::TimeWithZone
        date_value.in_time_zone(tz).to_date
      when Date
        date_value
      else
        nil
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("GocardlessAccount::DataHelpers - Failed to parse date: #{date_value.inspect} - #{e.message}")
      nil
    end

    # Handle currency as string or object (API inconsistency)
    def extract_currency(data, fallback: nil)
      data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)

      currency_data = data[:currency]
      return fallback if currency_data.blank?

      if currency_data.is_a?(Hash)
        currency_data.with_indifferent_access[:code] || fallback
      elsif currency_data.is_a?(String)
        currency_data.upcase
      else
        fallback
      end
    end
end
