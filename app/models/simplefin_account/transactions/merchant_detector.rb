require "digest/md5"

# Detects and creates merchant records from SimpleFin transaction data
# SimpleFin provides clean payee data that works well for merchant identification
class SimplefinAccount::Transactions::MerchantDetector
  def initialize(transaction_data, family:)
    @transaction_data = transaction_data.with_indifferent_access
    @family = family
  end

  def detect_merchant
    # SimpleFin provides clean payee data - use it directly
    payee = (transaction_data[:payee] || transaction_data["payee"])&.strip
    return nil unless payee.present?

    family.merchants.find_or_create_by!(name: payee, website_url: nil)
  end

  private
    attr_reader :transaction_data
    attr_reader :family
end
