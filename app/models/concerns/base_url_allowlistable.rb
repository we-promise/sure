# Shared F-08 SSRF hardening for provider items whose operators can configure
# an outbound `base_url` from the UI. Without validation a user could point
# server-side requests at internal endpoints (169.254.169.254 metadata,
# localhost, internal DNS, etc.).
#
# Usage:
#
#   class FooItem < ApplicationRecord
#     include BaseUrlAllowlistable
#     allowed_base_urls "https://api.foo.com/api/v1"
#   end
#
# Provides:
#   - ALLOWED_BASE_URLS class-level constant (array of strings)
#   - AR `inclusion` validation on `base_url` rejecting invalid values at save time
#   - `effective_base_url` instance helper that falls back to the canonical URL
#     with a single boot-time [SECURITY] log when an invalid value sneaks through
#
# Both the DB-level validation and the runtime helper are kept as
# defense-in-depth: validation catches bad input at the UI boundary, the
# helper guards against values written through rake tasks, console sessions,
# or direct DB updates.
module BaseUrlAllowlistable
  extend ActiveSupport::Concern

  class_methods do
    def allowed_base_urls(*urls)
      if const_defined?(:ALLOWED_BASE_URLS, false)
        raise ArgumentError,
          "#{name}.allowed_base_urls already configured — call it exactly once per class"
      end

      const_set(:ALLOWED_BASE_URLS, urls.flatten.freeze)
      # The validator resolves the allow-list via `const_get` on each call so
      # the inclusion check and `effective_base_url` can never drift. (A
      # literal `in: allowed` would freeze a snapshot at registration time.)
      validates :base_url,
        inclusion: { in: ->(record) { record.class.const_get(:ALLOWED_BASE_URLS) } },
        allow_blank: true
    end
  end

  def effective_base_url
    allowed = self.class.const_get(:ALLOWED_BASE_URLS)
    url = base_url.presence || allowed.first
    unless allowed.include?(url)
      Rails.logger.warn("[SECURITY] Rejected #{self.class.name} base_url: #{url.inspect}")
      return allowed.first
    end
    url
  end
end
