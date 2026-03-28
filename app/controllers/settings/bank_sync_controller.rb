class Settings::BankSyncController < ApplicationController
  layout "settings"

  def show
    @providers = [
      {
        name: "Lunch Flow",
        description: "US, Canada, UK, EU, Brazil and Asia through multiple open banking providers.",
        path: "https://lunchflow.app/features/sure-integration",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Plaid",
        description: "US & Canada bank connections with transactions, investments, and liabilities.",
        path: "https://github.com/we-promise/sure/blob/main/docs/hosting/plaid.md",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "SimpleFIN",
        description: "US & Canada connections via SimpleFIN protocol.",
        path: "https://beta-bridge.simplefin.org",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Enable Banking (beta)",
        description: "European bank connections via open banking APIs across multiple countries.",
        path: "https://enablebanking.com",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Binance (beta)",
        description: "Crypto spot account sync via a read-only Binance API key for balances, transfers, and trade history.",
        path: "https://developers.binance.com/docs/binance-spot-api-docs/rest-api/request-security",
        target: "_blank",
        rel: "noopener noreferrer"
      }
    ]
  end
end
