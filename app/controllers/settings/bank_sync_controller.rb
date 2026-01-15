class Settings::BankSyncController < ApplicationController
  layout "settings"

  def show
    @providers = [
      {
        name: "Lunch Flow",
        description: t("settings.bank_sync.show.lunchflow_description"),
        path: "https://lunchflow.app/features/sure-integration",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Plaid",
        description: t("settings.bank_sync.show.plaid_description"),
        path: "https://github.com/we-promise/sure/blob/main/docs/hosting/plaid.md",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "SimpleFIN",
        description: t("settings.bank_sync.show.simplefin_description"),
        path: "https://beta-bridge.simplefin.org",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: t("settings.bank_sync.show.enable_banking_name"),
        description: t("settings.bank_sync.show.enable_banking_description"),
        path: "https://enablebanking.com",
        target: "_blank",
        rel: "noopener noreferrer"
      }
    ]
  end
end
