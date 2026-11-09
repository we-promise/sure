# frozen_string_literal: true

module TricountItem::Provided
  extend ActiveSupport::Concern

  # A client for this connection's anonymous Tricount device. A device is made
  # the first time it is needed, and a session the client registers is kept
  # for the next sync.
  def tricount_provider
    return nil unless credentials_configured?

    ensure_device!
    Provider::Tricount.new(
      app_installation_uuid: app_installation_uuid,
      client_public_key: client_public_key,
      session_token: session_token,
      user_id: tricount_user_id,
      on_session: ->(session) { update!(session_token: session.token, tricount_user_id: session.user_id) }
    )
  end

  # The sharing tokens of the tricounts this connection follows.
  def sharing_token_list
    sharing_tokens.to_s.split(/\s+/).compact_blank.uniq
  end

  # Adds the tricounts behind these links (or bare tokens). Returns the tokens
  # that could not be read from the input.
  def add_sharing_links(input)
    parts = input.to_s.split(/[\s,]+/).compact_blank
    tokens = parts.map { |part| Provider::Tricount.sharing_token_from(part) }
    self.sharing_tokens = (sharing_token_list + tokens.compact).uniq.join("\n")
    parts.zip(tokens).filter_map { |part, token| part if token.nil? }
  end

  def remove_sharing_token(token)
    self.sharing_tokens = (sharing_token_list - [ token ]).join("\n")
  end

  private

    def ensure_device!
      return if app_installation_uuid.present? && client_public_key.present?

      device = Provider::Tricount.generate_device
      update!(**device, session_token: nil, tricount_user_id: nil)
    end
end
