class Settings::BankSyncController < ApplicationController
  layout "settings"

  def show
    @banks = [
      {
        name: "Wise",
        description: "Multi-currency accounts and international transfers via Wise API.",
        path: wise_items_path
      }
    ]

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
        name: "SimpleFin",
        description: "US & Canada connections via SimpleFin protocol.",
        path: simplefin_items_path
      },
      {
        name: "Wise (Direct API)",
        description: "Connect Wise via the new generalized direct API pipeline.",
        path: new_bank_connection_path(provider: :wise)
      },
      {
        name: "Mercury (Direct API)",
        description: "US business banking via Mercury APIs.",
        path: new_bank_connection_path(provider: :mercury)
      }
    ]
  end
end
