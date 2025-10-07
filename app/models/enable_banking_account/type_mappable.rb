module EnableBankingAccount::TypeMappable
  extend ActiveSupport::Concern

  UnknownAccountTypeError = Class.new(StandardError)

  def map_accountable(enable_banking_account_type)
    key = enable_banking_account_type.to_s.upcase.to_sym
    accountable_class = TYPE_MAPPING.dig(
      key,
      :accountable
    )

    unless accountable_class
      raise UnknownAccountTypeError, "Unknown account type: #{enable_banking_account_type}"
    end

    accountable_class.new
  end

  # Enable Banking Types -> Accountable Types
  # https://enablebanking.com/docs/api/reference/#cashaccounttype
  TYPE_MAPPING = {
    CACC: {
      accountable: Depository
    },
    CASH: {
      accountable: Depository
    },
    CARD: {
      accountable: CreditCard
    },
    LOAN: {
      accountable: Loan
    },
    OTHR: {
      accountable: OtherAsset
    }
  }
end
