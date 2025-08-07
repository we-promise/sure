class SimplefinItem::Importer
  attr_reader :simplefin_item, :simplefin_provider

  def initialize(simplefin_item, simplefin_provider:)
    @simplefin_item = simplefin_item
    @simplefin_provider = simplefin_provider
  end

  def import
    accounts_data = simplefin_provider.get_accounts(simplefin_item.access_url)

    # Handle errors if present
    if accounts_data[:errors] && accounts_data[:errors].any?
      handle_errors(accounts_data[:errors])
      return
    end

    # Store raw payload
    simplefin_item.upsert_simplefin_snapshot!(accounts_data)

    # Import accounts - accounts_data[:accounts] is an array
    accounts_data[:accounts]&.each do |account_data|
      import_account(account_data)
    end
  end

  private

    def import_account(account_data)
      # Import organization data from the account if present and not already imported
      if account_data[:org] && simplefin_item.institution_id.blank?
        import_organization(account_data[:org])
      end

      simplefin_account = simplefin_item.simplefin_accounts.find_or_initialize_by(
        account_id: account_data[:id]
      )

      simplefin_account.upsert_simplefin_snapshot!(account_data)

      # Import transactions if present
      if account_data[:transactions] && account_data[:transactions].any?
        simplefin_account.upsert_simplefin_transactions_snapshot!(account_data[:transactions])
      end
    end

    def import_organization(org_data)
      simplefin_item.upsert_simplefin_institution_snapshot!({
        id: org_data[:domain] || org_data[:"sfin-url"],
        name: org_data[:name] || extract_domain_name(org_data[:domain]),
        url: org_data[:domain] || org_data[:"sfin-url"]
      })
    end

    def extract_domain_name(domain)
      return "Unknown Institution" if domain.blank?

      # Extract a readable name from domain like "mybank.com" -> "Mybank"
      domain.split(".").first.capitalize
    end

    def handle_errors(errors)
      error_messages = errors.map { |error| error[:description] || error[:message] }.join(", ")

      # Mark item as requiring update for certain error types
      if errors.any? { |error| error[:code] == "auth_failure" || error[:code] == "token_expired" }
        simplefin_item.update!(status: :requires_update)
      end

      raise Provider::Simplefin::SimplefinError.new(
        "SimpleFin API errors: #{error_messages}",
        :api_error
      )
    end
end
