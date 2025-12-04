module Family::EnableBankingConnectable
  extend ActiveSupport::Concern

  included do
    has_many :enable_banking_items, dependent: :destroy
  end

  def can_connect_enable_banking?
    # Families can configure their own Enable Banking credentials
    true
  end

  def create_enable_banking_item!(country_code:, application_id:, client_certificate:, item_name: nil)
    enable_banking_item = enable_banking_items.create!(
      name: item_name || "Enable Banking Connection",
      country_code: country_code,
      application_id: application_id,
      client_certificate: client_certificate
    )

    enable_banking_item
  end

  def has_enable_banking_credentials?
    enable_banking_items.where.not(client_certificate: nil).exists?
  end

  def has_enable_banking_session?
    enable_banking_items.where.not(session_id: nil).exists?
  end
end
