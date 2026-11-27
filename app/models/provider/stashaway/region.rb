# The regions StashAway's web app serves, each with its own API host. The
# hosts answer the same login and GraphQL requests.
class Provider::Stashaway::Region
  attr_reader :code, :api_domain, :name_prefix

  def initialize(code:, api_domain:, name_prefix:)
    @code = code
    @api_domain = api_domain
    @name_prefix = name_prefix
  end

  ALL = [
    new(code: "sg", api_domain: "sg", name_prefix: "SG"),
    new(code: "my", api_domain: "my", name_prefix: "MY"),
    new(code: "hk", api_domain: "hk", name_prefix: "HK"),
    # StashAway runs its UAE business as MENA.
    new(code: "ae", api_domain: "ae", name_prefix: "MENA"),
    new(code: "th", api_domain: "co.th", name_prefix: "TH")
  ].freeze

  DEFAULT_CODE = "sg".freeze

  class << self
    def codes
      ALL.map(&:code)
    end

    def find(code)
      ALL.find { |region| region.code == code.to_s } || raise(ArgumentError, "Unknown StashAway region: #{code.inspect}")
    end
  end

  def base_uri
    "https://api.stashaway.#{api_domain}"
  end

  def label
    I18n.t("stashaway_items.regions.#{code}")
  end
end
