# A disk service URL is only valid for ActiveStorage.service_urls_expire_in and
# always names the same file, so the browser can keep what it serves for that
# long without asking again. Without a freshness lifetime, browsers revalidate
# each use: iOS Safari does so when it restores a page from its back/forward
# cache (`pageshow`), and when it has already dropped the image it fails the
# 304 Not Modified it gets back, so stored logos vanish (their initials show).
#
# Only account logos are kept this way. A cached response is served without
# reaching the server, so the authorization in active_storage_authorization.rb
# would not run again for it; files whose access is checked (statements,
# attachments, exports) keep Rails' revalidate-every-time policy.
Rails.application.config.to_prepare do
  module ActiveStorageDiskCaching
    extend ActiveSupport::Concern

    CACHEABLE_ATTACHMENTS = [ %w[Account logo] ].freeze

    included do
      after_action :cache_served_file, only: :show
    end

    private
      def cache_served_file
        return unless response.status.in?([ 200, 206, 304 ])
        return unless cacheable_file?

        expires_in ActiveStorage.service_urls_expire_in, public: false, immutable: true
      end

      # Every attachment of the blob (or of the blob a variant derives from) is
      # one the browser may keep: a file shared with anything else is not.
      def cacheable_file?
        attachments = respond_to?(:authorized_attachments, true) ? authorized_attachments : nil
        attachments.present? && attachments.all? { |attachment| CACHEABLE_ATTACHMENTS.include?([ attachment.record_type, attachment.name ]) }
      end
  end

  if defined?(ActiveStorage::DiskController) && !ActiveStorage::DiskController.include?(ActiveStorageDiskCaching)
    ActiveStorage::DiskController.include ActiveStorageDiskCaching
  end
end
