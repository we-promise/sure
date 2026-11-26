class ScalableCapitalItem::Discovery
  Choice = Data.define(:kind, :id, :label, :owner_kind)

  attr_reader :identity, :choices, :savings_unavailable

  def initialize(client: Provider::ScalableCapital.new)
    @client = client
    @savings_unavailable = false
  end

  def fetch
    ScalableCapitalItem.with_cli_lock do
      @identity = @client.identity
      portfolios = @client.portfolios.map { |id| Choice.new(kind: "brokerage", id: id, label: nil, owner_kind: "personal") }
      @choices = portfolios + savings_choices
    end
    self
  end

  private

    def savings_choices
      @client.overnight_accounts.map do |data|
        id = data["savings_account_id"]
        account = data["account"]
        unless ScalableCapitalItem.valid_source_id?(id) && account.is_a?(Hash) && account["is_active"] == true &&
            %w[personal junior].include?(account["owner_kind"])
          raise Provider::ScalableCapital::InvalidResponse, "Scalable returned an invalid Overnight Savings account"
        end

        label = account["display_name"].to_s.gsub(/[[:cntrl:]]/, " ").strip.first(80).presence
        Choice.new(kind: "savings", id: id, label: label, owner_kind: account["owner_kind"])
      end.uniq(&:id)
    rescue Provider::ScalableCapital::OvernightDiscoveryUnavailable
      @savings_unavailable = true
      []
    end
end
