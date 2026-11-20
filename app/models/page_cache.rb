# Pages that are slow to build (today the Reports body), kept in Rails.cache
# and served stale while a newer version is built in the background.
#
# Each page is stored under a key that names the page (whose, which period and
# filters), together with the `version` of the data it was built from. When the
# data has moved on, the stored page is still served at once, marked stale, and
# a rebuild is queued, at most once per Setting.page_cache_cooldown. Only a
# page that was never built, or an explicit refresh, is built while the member
# waits.
#
# A page belongs to one member of one family, and that is enforced, not assumed:
# it is encrypted with a key derived for its family from SECRET_KEY_BASE and
# bound to its cache key, and carries its family and member ids, which are
# checked on every read. A page that doesn't decrypt with the reader's family
# key, or names anyone else, is treated as missing. Nothing readable is stored
# in the cache, and PageCacheEntry holds only keys, sizes and times.
#
# A PageCacheEntry records each page's size and last use, so the pages are held
# under Setting.page_cache_max_mb together: when a new page would go over it,
# the pages served longest ago are dropped first. A page bigger than the whole
# limit is served but never kept.
class PageCache
  Served = Data.define(:body, :built_at, :stale)

  # A served page records its use at most this often, so reading the cache
  # doesn't mean a write on every page view.
  TOUCH_INTERVAL = 1.hour
  # How long a queued rebuild holds its claim; a job that dies frees it then.
  REBUILD_CLAIM_TTL = 30.minutes

  class << self
    # `rebuild_later` queues the background rebuild; it is called only when the
    # stored page is stale, past its cooldown and no rebuild is claimed yet.
    def serve(key, version:, family:, user:, rebuild_later:, refresh: false)
      entry = read(key, family: family, user: user) unless refresh

      if entry.nil?
        started_at = Time.current
        body = yield
        write(key, body, version: version, family: family, user: user, started_at: started_at)
        return Served.new(body: body, built_at: Time.current, stale: false)
      end

      stale = entry[:version] != version
      if stale && entry[:built_at] <= Setting.page_cache_cooldown.ago && claim_rebuild(key)
        queue_rebuild(key, rebuild_later)
      end

      Served.new(body: entry[:body], built_at: entry[:built_at], stale: stale)
    end

    def current?(key, version:, family:, user:)
      read(key, family: family, user: user, touch: false)&.dig(:version) == version
    end

    # Returns whether the page was kept. `started_at` is when its build began:
    # a build that began before the stored page's did is from older data, so a
    # slow builder finishing last never replaces a newer page.
    def write(key, body, version:, family:, user:, started_at: Time.current)
      release_rebuild(key)
      stored = read(key, family: family, user: user, touch: false)
      return false if stored && stored[:started_at] > started_at

      entry = {
        family_id: family.id, user_id: user.id, version: version,
        started_at: started_at.iso8601(6), built_at: Time.current.iso8601(6), body: body
      }
      sealed = encryptor_for(family).encrypt_and_sign(entry, purpose: key)
      bytes = sealed.bytesize

      if bytes > max_bytes
        forget(PageCacheEntry.where(page_key: key))
        return false
      end

      Rails.cache.write(key, sealed, expires_in: Setting.page_cache_ttl)
      PageCacheEntry.upsert(
        { page_key: key, family_id: family.id, bytes: bytes, last_used_at: Time.current },
        unique_by: :page_key
      )
      evict_to_fit
      true
    end

    def total_bytes
      PageCacheEntry.sum(:bytes)
    end

    def max_bytes
      Setting.page_cache_max_mb_in_effect.megabytes
    end

    private
      def read(key, family:, user:, touch: true)
        sealed = Rails.cache.read(key)
        entry = unseal(sealed, key: key, family: family)
        return unless entry && entry[:family_id] == family.id && entry[:user_id] == user.id

        touch(key, sealed) if touch
        entry.merge(
          built_at: Time.zone.parse(entry[:built_at]),
          started_at: entry[:started_at] ? Time.zone.parse(entry[:started_at]) : Time.zone.parse(entry[:built_at])
        )
      end

      # Records the use, at most once per TOUCH_INTERVAL, and renews the cache
      # store's expiry with it: a page kept "for N days unopened" must not
      # expire N days after it was built while it is still being opened.
      def touch(key, sealed)
        touched = PageCacheEntry.where(page_key: key, last_used_at: ...TOUCH_INTERVAL.ago).update_all(last_used_at: Time.current)
        Rails.cache.write(key, sealed, expires_in: Setting.page_cache_ttl) if touched.positive?
      end

      # A rebuild that can't be queued leaves the stale page served and the
      # claim released, so the next visit tries again.
      def queue_rebuild(key, rebuild_later)
        rebuild_later.call
      rescue StandardError => e
        release_rebuild(key)
        Rails.logger.error("[PageCache] could not queue a rebuild of #{key}: #{e.class}: #{e.message}")
      end

      def unseal(sealed, key:, family:)
        return unless sealed.is_a?(String)

        encryptor_for(family).decrypt_and_verify(sealed, purpose: key)
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
        nil
      end

      def encryptor_for(family)
        key = Rails.application.key_generator.generate_key("page_cache/#{family.id}", 32)
        ActiveSupport::MessageEncryptor.new(key, serializer: CompressedJson)
      end

      def claim_rebuild(key)
        Rails.cache.write(rebuild_claim_key(key), true, unless_exist: true, expires_in: REBUILD_CLAIM_TTL)
      end

      def release_rebuild(key)
        Rails.cache.delete(rebuild_claim_key(key))
      end

      def rebuild_claim_key(key)
        "#{key}/rebuilding"
      end

      def evict_to_fit
        forget(PageCacheEntry.where(last_used_at: ...Setting.page_cache_ttl.ago))

        excess = total_bytes - max_bytes
        return if excess <= 0

        freed = 0
        doomed = PageCacheEntry.order(:last_used_at).pluck(:id, :bytes).take_while do |_, bytes|
          (freed < excess).tap { freed += bytes }
        end
        forget(PageCacheEntry.where(id: doomed.map(&:first)))
      end

      def forget(entries)
        entries.pluck(:id, :page_key).each_slice(500) do |rows|
          Rails.cache.delete_multi(rows.map(&:last))
          PageCacheEntry.where(id: rows.map(&:first)).delete_all
        end
      end
  end

  # Compressed before it is encrypted: the cache store's own compression can't
  # shrink ciphertext, and a page's HTML compresses about tenfold. JSON rather
  # than Marshal, so loading a page can never run code; keys come back as
  # symbols, and times are stored as ISO 8601 strings.
  module CompressedJson
    def self.dump(value)
      Zlib::Deflate.deflate(JSON.generate(value))
    end

    def self.load(data)
      JSON.parse(Zlib::Inflate.inflate(data)).deep_symbolize_keys
    end
  end
end
