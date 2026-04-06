module Bond::InflationProvider
  PROVIDERS = {
    "gus_sdp" => "Provider::GusSdp",
    "us_bls" => "Provider::UsBlsCpi",
    "es_ine" => "Provider::EsIneCpi"
  }.freeze

  module_function

  def valid?(provider)
    provider.blank? || PROVIDERS.key?(provider)
  end
end
