# frozen_string_literal: true

class RevolutXItem::Syncer < ProviderItem::Syncer
  private

    def credentials_error?(error)
      error.is_a?(Provider::RevolutX::AuthenticationError)
    end
end
