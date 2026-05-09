class Settings::BankSyncController < ApplicationController
  layout "settings"

  def show
    static_providers = [
      {
        name: "Lunch Flow",
        description: "US, Canada, UK, EU, Brazil and Asia through multiple open banking providers.",
        color: "#6471eb",
        path: "https://lunchflow.app/features/sure-integration?atp=BiDIYS",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Plaid",
        description: "US & Canada bank connections with transactions, investments, and liabilities.",
        color: "#4da568",
        path: "https://github.com/we-promise/sure/blob/main/docs/hosting/plaid.md",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "SimpleFIN",
        description: "US & Canada connections via SimpleFIN protocol.",
        color: "#e99537",
        path: "https://beta-bridge.simplefin.org",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Enable Banking",
        description: "European bank connections via open banking APIs across multiple countries.",
        color: "#6471eb",
        beta: true,
        path: "https://enablebanking.com",
        target: "_blank",
        rel: "noopener noreferrer"
      },
      {
        name: "Sophtron",
        description: "US & Canada bank, credit card, investment, loan, insurance, utility, and other connections.",
        color: "#1E90FF",
        beta: true,
        path: "https://www.sophtron.com/",
        target: "_blank",
        rel: "noopener noreferrer"
      }
    ]

    connection_providers = Provider::ConnectionRegistry.keys.map do |key|
      adapter = Provider::ConnectionRegistry.adapter_for(key)
      {
        name:        adapter.display_name,
        description: adapter.respond_to?(:description) ? adapter.description : nil,
        color:       adapter.respond_to?(:brand_color) ? adapter.brand_color : "#6B7280",
        beta:        adapter.beta?,
        path:        Current.user&.admin? ? settings_providers_path : nil
      }
    end

    @providers = static_providers + connection_providers
  end
end
