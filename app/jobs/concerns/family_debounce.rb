# Debounces a job per family. Every schedule stores a fresh token in the
# cache, and only the run carrying the stored token proceeds. Unlike a
# timestamp, a token cannot tie with another schedule or be outranked by a
# cache write that lands out of order.
module FamilyDebounce
  extend ActiveSupport::Concern

  included do
    class_attribute :debounce_key_prefix, instance_writer: false
  end

  class_methods do
    def debounce_key(family_id)
      "#{debounce_key_prefix}:#{family_id}"
    end

    # Stores and returns the token of the family's newest scheduled run.
    def claim_debounce_token(family_id, expires_in:)
      SecureRandom.uuid.tap do |token|
        Rails.cache.write(debounce_key(family_id), token, expires_in: expires_in)
      end
    end
  end

  private
    # A missing key (expired, or a cache store that keeps nothing) lets the
    # run proceed, so the job degrades to running once per schedule.
    def superseded?(family_id, token)
      latest = Rails.cache.read(self.class.debounce_key(family_id))
      latest.present? && latest != token
    end
end
