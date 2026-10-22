require "test_helper"

class SaxoItemConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "simultaneous refreshes spend the rotating token once" do
    Setting.saxo_app_key = "concurrency-key"
    Setting.saxo_app_secret = "concurrency-secret"
    item = families(:dylan_family).saxo_items.create!(access_token: "old", refresh_token: "old-refresh",
      access_expires_at: 1.minute.from_now, refresh_expires_at: 30.minutes.from_now,
      application_key_digest: Provider::Saxo.application_key_digest)
    stub_request(:post, "#{Provider::Saxo::AUTH_URL}/token").to_return(body: {
      access_token: "rotated", refresh_token: "rotated-refresh", expires_in: 1200, refresh_token_expires_in: 2400
    }.to_json)
    ready, release = Queue.new, Queue.new
    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          instance = SaxoItem.find(item.id)
          ready << true
          release.pop
          instance.access_token!
        end
      end
    end
    2.times { ready.pop }
    2.times { release << true }
    assert_equal [ "rotated", "rotated" ], workers.map(&:value)
    assert_requested :post, "#{Provider::Saxo::AUTH_URL}/token", times: 1
    assert_equal "rotated-refresh", item.reload.refresh_token
  ensure
    workers&.each { |worker| worker.join(5) }
    item&.destroy!
    Setting.where(var: %w[saxo_app_key saxo_app_secret]).destroy_all
    Setting.clear_cache
  end
end
