module EnableBankingItem::Provided
  extend ActiveSupport::Concern

  def enable_banking_provider(sync_budget: nil)
    return nil unless credentials_configured?

    Provider::EnableBanking.new(
      application_id: application_id,
      client_certificate: client_certificate,
      sync_budget: sync_budget
    )
  end

  # a live user request can send its own IP and user-agent. Background jobs
  # deliberately send no PSU headers, and historical IP values are never reused.
  def build_psu_headers(psu_context: nil)
    return {} unless psu_context.present?
    return {} unless NetworkAddress.public?(psu_context["ip_address"])

    required = Array(aspsp_required_psu_headers).map(&:downcase)
    available = {
      "psu-ip-address" => psu_context["ip_address"],
      "psu-user-agent" => psu_context["user_agent"]
    }.compact
    return {} unless required.all? { |header| available[header].present? }

    available.transform_keys { |header| header.split("-").map(&:capitalize).join("-") }
  end

end
