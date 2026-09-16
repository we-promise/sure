# Read under RuntimeInputs' settings lock. Values stay inside the application
# context; only keyed fingerprints enter request evidence.
class Provider::AccountData::OnchainWallet::Configuration
  def self.build
    plural = ENV["SECURITIES_PROVIDERS"].presence || setting("securities_providers").presence
    providers = plural ? plural.to_s.split(",").map(&:strip) : [ ENV["SECURITIES_PROVIDER"].presence || setting("securities_provider") ]
    {
      "bitcoin_url" => Provider::MempoolSpace.base_url,
      "solana_url" => Provider::SolanaRpc.url,
      "token_list_url" => Provider::JupiterTokens.url,
      "price_url" => ENV["BINANCE_PUBLIC_URL"].presence || "https://data-api.binance.vision",
      "price_enabled" => providers.include?("binance_public"),
      "fx" => Provider::AccountData::OnchainWallet::FxConfiguration.options,
      "history_pages" => Onchain::HistoryBudget.pages,
      "history_transactions" => Onchain::HistoryBudget.transactions,
      "asset_tokens" => Onchain::AssetBudget.tokens,
      "chains" => Onchain::Chains.all.to_h do |definition|
        options = definition.adapter_options.stringify_keys
        [ definition.key, {
          "adapter" => definition.adapter_class_name, "token_kind" => definition.token_kind,
          "native" => definition.native.to_h.stringify_keys,
          "explorer_url" => options["explorer_url"] && (ENV["BLOCKSCOUT_#{definition.key.upcase}_URL"].presence || options["explorer_url"]),
          "etherscan_chain_id" => options["etherscan_chain_id"]
        } ]
      end
    }
  end

  def self.setting(key)
    field = Setting.defined_fields.find { |definition| definition.key == key } || raise(ArgumentError)
    Setting.uncached do
      stored = Setting.unscoped.find_by(var: key)&.value
      field.deserialize(field.readonly || stored.nil? ? field.default_value : stored)
    end
  end
  private_class_method :setting
end
