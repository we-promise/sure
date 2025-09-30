class Provider::Banks::Wise < Provider::Banks::Base
  class Mapper < Provider::Banks::Mapper
    def normalize_account(payload)
      data = payload.with_indifferent_access
      amount = data[:amount] || {}
      {
        provider_account_id: data[:id].to_s,
        name: data[:name].presence || (amount[:currency] ? "Wise #{amount[:currency]} Account" : "Wise Account"),
        currency: amount[:currency] || data[:currency],
        current_balance: to_decimal(amount[:value]),
        available_balance: to_decimal(amount[:value])
      }
    end

    def normalize_transaction(payload, currency:)
      data = payload.with_indifferent_access
      amount_value = case data[:amount]
      when Hash then data[:amount][:value]
      else data[:amount]
      end

      amount = to_decimal(amount_value)
      # Convert Wise convention (expense negative) to internal (expense positive)
      normalized_amount = -amount

      {
        external_id: "wise_#{data[:referenceNumber] || data[:id]}",
        posted_at: parse_date(data[:date]).to_date,
        amount: normalized_amount,
        description: data.dig(:details, :description) ||
                     data.dig(:details, :merchant, :name) ||
                     data.dig(:details, :paymentReference) ||
                     data.dig(:exchangeDetails, :description) ||
                     data[:type] ||
                     "Wise transaction"
      }
    end

    private
      def to_decimal(val)
        BigDecimal(val.to_s)
      rescue
        BigDecimal("0")
      end

      def parse_date(val)
        case val
        when String then DateTime.parse(val)
        when Integer, Float then Time.at(val)
        when Time, DateTime, Date then val
        else Time.current
        end
      end
  end

  def verify_credentials!
    client.get_profiles
    true
  rescue Provider::Wise::WiseError => e
    raise e
  end

  # Returns array of Wise balances across all profiles
  def list_accounts
    profiles = client.get_profiles
    balances = []
    profiles.each do |p|
      profile_id = p[:id]
      balances.concat(Array(client.get_accounts(profile_id)))
    end
    balances
  end

  # Return the statement transactions for the account. We need the profile_id to fetch transactions
  # but the generic interface passes only account_id. We'll scan profiles to find the balance id.
  def list_transactions(account_id:, start_date:, end_date:)
    profiles = client.get_profiles
    profiles.each do |p|
      profile_id = p[:id]
      accounts = Array(client.get_accounts(profile_id))
      match = accounts.find { |a| a[:id].to_s == account_id.to_s }
      next unless match
      statement = client.get_transactions(profile_id, match[:id], start_date: start_date, end_date: end_date)
      return Array(statement[:transactions])
    end
    []
  end

  private
    def client
      @client ||= Provider::Wise.new(@credentials[:api_key])
    end
end

