module Family::EnableBankingConnectable
  extend ActiveSupport::Concern

  included do
    has_many :enable_banking_items, dependent: :destroy
  end

  def create_enable_banking_item!(enable_banking_id:, session_id:)
    session = enable_banking_provider.create_session(session_id)
    enable_banking_item = enable_banking_items.find_or_create_by(id: enable_banking_id)

    enable_banking_item.update!(
      session_id: session["session_id"],
      valid_until: session["access"]["valid_until"],
      status: "good",
      aspsp_name: session["aspsp"]["name"],
      aspsp_country: session["aspsp"]["country"],
      logo_url: "https://enablebanking.com/brands/#{session['aspsp']['country']}/#{session['aspsp']['name']}",
      raw_payload: session.to_json
    )

    enable_banking_item.sync_later

    enable_banking_item
  end

  private
    def enable_banking_provider
      Provider::Registry.get_provider(:enable_banking)
    end
end
