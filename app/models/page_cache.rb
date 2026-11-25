# Pages that are slow to build (today the Reports body), kept in Rails.cache
# and served stale while a newer version is built in the background.
#
# Each page is stored under a key that names the page (whose, which period and
# filters), together with the `version` of the data it was built from. When the
# data has moved on, the stored page is still served at once, marked stale, and
# a rebuild is queued, no sooner than Setting.page_cache_cooldown after the last
# build of that page finished, whether or not it was kept. Only a
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
#
# Replacing a page and renewing its expiry hold a lock on its key, so a slower,
# older build or a renewal can never put back a page that was just replaced.
# Under the lock the page is read from the shared store, not from what Rails'
# per-request local cache kept from earlier in the request.
class PageCache
  # `kept` is whether the page is in the cache after serving it.
  Served = Data.define(:body, :built_at, :stale, :kept)

  # A served page records its use at most this often, so reading the cache
  # doesn't mean a write on every page view.
  TOUCH_INTERVAL = 1.hour
  # How long a queued rebuild holds its claim; a job that dies frees it then.
  REBUILD_CLAIM_TTL = 30.minutes
  PAGE_LOCK_NAMESPACE = 4015

  class << self
    # `rebuild_later` queues the background rebuild; it is called only when the
    # stored page is stale, past its cooldown and no rebuild is claimed yet.
    def serve(key, version:, family:, user:, rebuild_later:, refresh: false)
      entry = read(key, family: family, user: user) unless refresh

      if entry.nil?
        started_at = Time.current
        body = yield
        kept = write(key, body, version: version, family: family, user: user, started_at: started_at)
        return Served.new(body: body, built_at: Time.current, stale: false, kept: kept)
      end

      stale = entry[:version] != version
      if stale && entry[:built_at] <= Setting.page_cache_cooldown.ago && !cooling_down?(key) && claim_rebuild(key)
        queue_rebuild(key, rebuild_later)
      end

      Served.new(body: entry[:body], built_at: entry[:built_at], stale: stale, kept: true)
    end

    def current?(key, version:, family:, user:)
      read(key, family: family, user: user, touch: false)&.dig(:version) == version
    end

    # Returns whether the page was kept. `started_at` is when its build began:
    # a build that began before the stored page's did is from older data, so a
    # slow builder finishing last never replaces a newer page.
    def write(key, body, version:, family:, user:, started_at: Time.current)
      release_rebuild(key)
      start_cooldown(key)
      kept = with_page_lock(key) do
        stored = read(key, family: family, user: user, touch: false, shared: true)
        next false if stored && stored[:started_at] > started_at

        entry = {
          family_id: family.id, user_id: user.id, version: version,
          started_at: started_at.iso8601(6), built_at: Time.current.iso8601(6), body: body
        }
        sealed = encryptor_for(family).encrypt_and_sign(entry, purpose: key)
        bytes = sealed.bytesize

        # Too big to keep: not stored, and an earlier build of this page stays.
        # It is still served (stale) rather than leaving the next visitor to
        # wait for a build.
        next false if bytes > max_bytes

        next false unless Rails.cache.write(key, sealed, expires_in: Setting.page_cache_ttl)

        PageCacheEntry.upsert(
          { page_key: key, family_id: family.id, bytes: bytes, last_used_at: Time.current },
          unique_by: :page_key
        )
        true
      end

      evict_to_fit if kept
      kept
    end

    def total_bytes
      PageCacheEntry.sum(:bytes)
    end

    def max_bytes
      Setting.page_cache_max_mb_in_effect.megabytes
    end

    private
      def read(key, family:, user:, touch: true, shared: false)
        sealed = shared ? read_shared(key) : Rails.cache.read(key)
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
      # expire N days after it was built while it is still being opened. The
      # store can only renew by writing the page again, so that happens only
      # while the page read is still the one stored.
      def touch(key, sealed)
        touched = PageCacheEntry.where(page_key: key, last_used_at: ...TOUCH_INTERVAL.ago).update_all(last_used_at: Time.current)
        return unless touched.positive?

        with_page_lock(key) do
          Rails.cache.write(key, sealed, expires_in: Setting.page_cache_ttl) if read_shared(key) == sealed
        end
      end

      # Another process may have replaced the page since this request first read
      # it, so the store itself is read: an empty local cache for the read forgets
      # what this request kept, and stores without one read the store anyway.
      def read_shared(key)
        return Rails.cache.read(key) unless Rails.cache.respond_to?(:with_local_cache)

        Rails.cache.with_local_cache { Rails.cache.read(key) }
      end

      # Held until the transaction ends, by every process sharing the database.
      def with_page_lock(key)
        PageCacheEntry.transaction do
          PageCacheEntry.connection.execute(
            PageCacheEntry.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, hashtext(?))", PAGE_LOCK_NAMESPACE, key ])
          )
          yield
        end
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

      # A build that isn't kept (too big, or older than the stored page) leaves
      # the stored page's built_at as it was, so the cooldown is also counted
      # from when the last build finished. A cooldown of 0 never holds one back.
      def start_cooldown(key)
        cooldown = Setting.page_cache_cooldown
        Rails.cache.write(rebuild_cooldown_key(key), true, expires_in: cooldown) if cooldown.positive?
      end

      def cooling_down?(key)
        Rails.cache.exist?(rebuild_cooldown_key(key))
      end

      def rebuild_cooldown_key(key)
        "#{key}/rebuilt"
      end

      def evict_to_fit
        forget(PageCacheEntry.where(last_used_at: ...Setting.page_cache_ttl.ago))

        # A page renewed or replaced since it was chosen is skipped, so choose
        # again from what remains until the cache fits or nothing is left to drop.
        tried = []
        while (excess = total_bytes - max_bytes).positive?
          freed = 0
          chosen = PageCacheEntry.where.not(id: tried).order(:last_used_at).pluck(:id, :page_key, :bytes, :last_used_at).take_while do |_, _, bytes, _|
            (freed < excess).tap { freed += bytes }
          end
          break if chosen.empty?

          forget_rows(chosen)
          tried.concat(chosen.map(&:first))
        end
      end

      def forget(entries)
        forget_rows(entries.pluck(:id, :page_key, :bytes, :last_used_at))
      end

      # Each page is dropped under its lock, and only if its entry is still the
      # one chosen: a page replaced meanwhile keeps its new copy and its entry.
      def forget_rows(rows)
        rows.each do |id, key, bytes, last_used_at|
          with_page_lock(key) do
            next unless PageCacheEntry.where(id: id, bytes: bytes, last_used_at: last_used_at).delete_all.positive?

            Rails.cache.delete(key)
          end
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
