require "test_helper"

class PageCacheTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "a page that was never built is built and kept" do
    served = PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { flunk "nothing to rebuild" }) { "body" }

    assert_equal "body", served.body
    assert_not served.stale
    assert PageCacheEntry.exists?(page_key: "page/a")
  end

  test "a page built from older data is served stale and rebuilt once its cooldown has passed" do
    PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "old" }
    rebuilds = 0

    served = PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: -> { rebuilds += 1 }) { flunk "must not build" }
    assert_equal [ "old", true, 0 ], [ served.body, served.stale, rebuilds ], "within the cooldown"

    travel Setting.page_cache_cooldown + 1.minute do
      2.times { PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: -> { rebuilds += 1 }) { flunk "must not build" } }
      assert_equal 1, rebuilds, "one rebuild is claimed, however many visits"

      PageCache.write("page/a", "new", version: "v2", family: @family, user: @user)
      served = PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: -> { flunk "current" }) { flunk "current" }
      assert_equal [ "new", false ], [ served.body, served.stale ]
    end
  end

  test "refresh builds the page even when a current one is kept" do
    PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "old" }

    served = PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }, refresh: true) { "fresh" }

    assert_equal "fresh", served.body
  end

  # The 99 MB page, then a 2 MB one, under a 100 MB limit, scaled down.
  test "going over the limit drops the pages served longest ago" do
    # Random text, so compression can't shrink it much.
    PageCache.stubs(:max_bytes).returns(200_000)
    PageCache.write("page/big", SecureRandom.alphanumeric(140_000), version: "v1", family: @family, user: @user)
    assert_equal %w[page/big], PageCacheEntry.pluck(:page_key)

    travel 1.minute do
      PageCache.write("page/small", SecureRandom.alphanumeric(20_000), version: "v1", family: @family, user: @user)
    end

    assert_equal %w[page/small], PageCacheEntry.pluck(:page_key)
    assert_nil Rails.cache.read("page/big")
    assert_operator PageCache.total_bytes, :<=, 200_000
  end

  test "a page bigger than the whole limit is served but not kept" do
    PageCache.stubs(:max_bytes).returns(1_000)
    PageCache.write("page/small", "x" * 100, version: "v1", family: @family, user: @user)

    served = PageCache.serve("page/huge", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { SecureRandom.alphanumeric(5_000) }

    assert_equal 5_000, served.body.bytesize
    assert_nil Rails.cache.read("page/huge")
    assert_equal %w[page/small], PageCacheEntry.pluck(:page_key), "the pages already kept stay"
  end

  test "a page the cache store refuses is served but not kept" do
    Rails.cache.stubs(:write).returns(false)

    served = PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "body" }

    assert_equal "body", served.body
    assert_not served.kept
    assert_not PageCacheEntry.exists?(page_key: "page/a")
  end

  test "pages unopened for longer than the keep time are forgotten" do
    PageCache.write("page/old", "old", version: "v1", family: @family, user: @user)

    travel Setting.page_cache_ttl + 1.day do
      PageCache.write("page/new", "new", version: "v1", family: @family, user: @user)
    end

    assert_equal %w[page/new], PageCacheEntry.pluck(:page_key)
  end

  test "a page is never served to another family, even under the same key" do
    other_family = families(:empty)
    other_user = users(:empty)
    PageCache.write("page/shared-key", "dylan's report", version: "v1", family: @family, user: @user)

    served = PageCache.serve("page/shared-key", version: "v1", family: other_family, user: other_user, rebuild_later: -> { }) { "their own" }

    assert_equal "their own", served.body
  end

  test "a page is never served to another member of the same family" do
    member = @family.users.where.not(id: @user.id).first
    PageCache.write("page/a", "admin's report", version: "v1", family: @family, user: @user)

    served = PageCache.serve("page/a", version: "v1", family: @family, user: member, rebuild_later: -> { }) { "member's own" }

    assert_equal "member's own", served.body
  end

  test "the cache holds the page encrypted and bound to its key" do
    PageCache.write("page/a", "Total income 12,345", version: "v1", family: @family, user: @user)
    sealed = Rails.cache.read("page/a")

    assert_not_includes sealed, "12,345"
    assert_not_includes Base64.decode64(sealed.split("--").first), "12,345"

    Rails.cache.write("page/b", sealed)
    served = PageCache.serve("page/b", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "rebuilt" }
    assert_equal "rebuilt", served.body, "a sealed page moved under another key does not open"
  end

  test "a tampered page is treated as missing" do
    PageCache.write("page/a", "report", version: "v1", family: @family, user: @user)
    Rails.cache.write("page/a", Rails.cache.read("page/a").reverse)

    served = PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "rebuilt" }

    assert_equal "rebuilt", served.body
  end

  test "a page is compressed before it is encrypted" do
    body = "<tr><td>Groceries</td><td>$123.45</td></tr>" * 2_000
    PageCache.write("page/a", body, version: "v1", family: @family, user: @user)

    assert_operator PageCacheEntry.find_by!(page_key: "page/a").bytes, :<, body.bytesize / 10
    assert_equal body, PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { flunk "kept" }.body
  end

  test "opening a page renews how long it is kept" do
    PageCache.write("page/a", "report", version: "v1", family: @family, user: @user)

    travel Setting.page_cache_ttl - 1.day do
      PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { flunk "kept" }
    end

    travel Setting.page_cache_ttl + 2.days do
      served = PageCache.serve("page/a", version: "v1", family: @family, user: @user, rebuild_later: -> { }) { "rebuilt" }
      assert_equal "report", served.body, "opened a day before it would have expired"
    end
  end

  test "renewing a page that was replaced meanwhile never puts the earlier one back" do
    PageCache.write("page/a", "earlier", version: "v1", family: @family, user: @user)
    earlier = Rails.cache.read("page/a")

    travel PageCache::TOUCH_INTERVAL + 1.minute do
      PageCache.write("page/a", "newer", version: "v2", family: @family, user: @user)
      PageCacheEntry.where(page_key: "page/a").update_all(last_used_at: 1.day.ago)

      PageCache.send(:touch, "page/a", earlier)

      served = PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: -> { }) { flunk "kept" }
      assert_equal "newer", served.body
    end
  end

  test "a build that began before the stored page's never replaces it" do
    slow_started = Time.current
    travel 1.minute do
      PageCache.write("page/a", "newer", version: "v2", family: @family, user: @user, started_at: Time.current)
    end

    travel 2.minutes do
      assert_not PageCache.write("page/a", "older", version: "v1", family: @family, user: @user, started_at: slow_started)
      served = PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: -> { }) { flunk "kept" }
      assert_equal "newer", served.body
    end
  end

  test "a rebuild that can't be queued still serves the stale page and tries again next time" do
    PageCache.write("page/a", "old", version: "v1", family: @family, user: @user)
    attempts = 0
    failing = -> { attempts += 1; raise "queue down" }

    travel Setting.page_cache_cooldown + 1.minute do
      2.times do
        served = PageCache.serve("page/a", version: "v2", family: @family, user: @user, rebuild_later: failing) { flunk "stale is served" }
        assert_equal [ "old", true ], [ served.body, served.stale ]
      end
    end

    assert_equal 2, attempts, "the failed attempt released its claim"
  end
end
