class Regions
  class << self
    def initialize_once
      @@data ||= load_regions
    end

    def country_to_region(country_code)
      initialize_once
      country_code = country_code.upcase if country_code.present?
      
      @@data[:country_region_map][country_code]
    end

    def currency_to_region(currency_code)
      initialize_once
      
      @@data[:currency_region_map][currency_code]
    end

    def region_for(country: nil, currency: nil)
      initialize_once
      
      # Prefer country if provided
      return country_to_region(country) if country.present?
      
      # Fallback to currency
      currency_to_region(currency) if currency.present?
    end

    private

    def load_regions
      config = YAML.safe_load(
        File.read(Rails.root.join("config/regions.yml")),
        permitted_classes: [Symbol]
      )

      # Build country -> region map
      country_region_map = {}
      (config["regions"] || {}).each do |region, data|
        (data["countries"] || []).compact.select { |c| c.is_a?(String) }.each do |country|
          country_region_map[country.upcase] = region
        end
      end

      # Build currency -> region map
      currency_region_map = (config["currencies"] || {}).transform_keys(&:to_s)

      {
        country_region_map: country_region_map,
        currency_region_map: currency_region_map
      }
    end
  end
end
