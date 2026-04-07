class InflationRateImporter
  SUPPORTED_PROVIDERS = %w[gus_sdp us_bls es_ine].freeze

  def initialize(start_year:, end_year:, force: false, providers: nil)
    @start_year = start_year.to_i
    @end_year = end_year.to_i
    @force = force
    @providers = normalize_providers(providers)
  end

  def import_all
    providers.index_with { |provider| import_provider(provider) }
  end

  private
    attr_reader :start_year, :end_year, :force, :providers

    def normalize_providers(providers)
      selected = Array(providers).presence || SUPPORTED_PROVIDERS
      selected.map(&:to_s).uniq.select { |provider| SUPPORTED_PROVIDERS.include?(provider) }
    end

    def import_provider(provider)
      case provider
      when "gus_sdp"
        GusInflationRate.import_range!(start_year:, end_year:, force:)
      when "us_bls", "es_ine"
        import_international_provider(provider)
      else
        0
      end
    end

    def import_international_provider(provider)
      provider_class = Bond::InflationProvider.provider_class(provider)
      provider_instance = Bond::InflationProvider.provider_instance_for(provider, provider_class)
      return 0 if provider_instance.blank?
      return 0 if provider == "es_ine" && es_ine_series_id.blank?

      (start_year..end_year).sum do |year|
        InflationRate.import_year!(
          source: provider,
          provider: provider_instance,
          year: year,
          force: force
        )
      end
    end

    def es_ine_series_id
      ENV["ES_INE_CPI_SERIES_ID"].presence || Setting.es_ine_cpi_series_id.presence
    end
end
