class BrexItem::Syncer < ProviderItem::Syncer
  private

    def credentials_error?(error)
      error.is_a?(Provider::Brex::BrexError) && error.error_type.in?([ :unauthorized, :access_forbidden ])
    end
end
