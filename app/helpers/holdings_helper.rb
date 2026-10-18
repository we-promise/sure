module HoldingsHelper
  def directa_backed_account?(account)
    account.account_providers.exists?(provider_type: "DirectaAccount")
  end
end
