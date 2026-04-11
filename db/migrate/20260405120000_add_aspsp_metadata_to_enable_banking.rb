class AddAspspMetadataToEnableBanking < ActiveRecord::Migration[7.2]
  def change
    # ASPSP-level metadata on the item (stored when user selects a bank)
    add_column :enable_banking_items, :aspsp_required_psu_headers, :jsonb, default: []
    add_column :enable_banking_items, :aspsp_maximum_consent_validity, :integer  # in seconds
    add_column :enable_banking_items, :aspsp_auth_approach, :string              # REDIRECT | EMBEDDED | DECOUPLED
    add_column :enable_banking_items, :aspsp_psu_types, :jsonb, default: []
    # PII/GDPR Notice: last_psu_ip stores the user's IP address.
    # - Required for the Psu-Ip-Address header in Enable Banking API requests
    # - Must be declared in the privacy policy
    # - Data retention: consider nullifying after session expiry or 90 days
    add_column :enable_banking_items, :last_psu_ip, :string                      # user IP captured at request time

    # Fix sync_start_date type: was datetime, should be date
    reversible do |dir|
      dir.up do
        # Truncate any non-midnight time components before converting datetime→date.
        # sync_start_date is a user-configured date — time components are meaningless.
        execute(<<~SQL)
          UPDATE enable_banking_items
          SET sync_start_date = DATE_TRUNC('day', sync_start_date)
          WHERE sync_start_date IS NOT NULL
            AND sync_start_date != DATE_TRUNC('day', sync_start_date)
        SQL
        change_column :enable_banking_items, :sync_start_date, :date
      end
      dir.down { change_column :enable_banking_items, :sync_start_date, :datetime }
    end

    # Account-level fields from AccountResource
    add_column :enable_banking_accounts, :product, :string                       # bank's proprietary product name
    add_column :enable_banking_accounts, :credit_limit, :decimal, precision: 19, scale: 4
    add_column :enable_banking_accounts, :identification_hashes, :jsonb, default: []
  end
end
