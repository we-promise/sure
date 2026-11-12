require "test_helper"
require "timeout"
require Rails.root.join("test/support/web_push_test_helper")

class WebPushDeliveryConcurrencyTest < ActiveSupport::TestCase
  include WebPushTestHelper
  self.use_transactional_tests = false

  test "re-registration completes during provider IO and a late gone response preserves the replacement" do
    user = users(:family_admin)
    original_preferences = user.preferences.deep_dup
    enable_web_push_preview(user)
    old_session = user.sessions.create!
    new_session = user.sessions.create!
    attributes = web_push_attributes
    subscription = register_web_push(user: user, session: old_session, **attributes)
    delivery = subscription.web_push_deliveries.create!(enqueued_at: Time.current)
    started = Queue.new
    release = Queue.new
    errors = Queue.new
    replacement = nil
    client = Object.new
    client.define_singleton_method(:deliver) do |**_arguments|
      started << true
      release.pop
      :gone
    end
    WebPush::Client.stubs(:configured?).returns(true)
    WebPush::Client.stubs(:new).returns(client)

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        DeliverWebPushNotificationJob.perform_now(web_push_delivery_id: delivery.id)
      end
    rescue => error
      errors << error
    end
    Timeout.timeout(10) { started.pop }
    registrar = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        replacement = WebPushSubscription.register_for!(user: User.find(user.id), session: Session.find(new_session.id), **attributes)
      end
    rescue => error
      errors << error
    end

    assert registrar.join(3), "Registration must not wait for a provider response or take an inverse delivery lock"
    release << true
    assert worker.join(10), "The late provider response must finish without deadlocking"
    assert errors.empty?, errors.empty? ? nil : errors.pop.full_message
    assert WebPushSubscription.exists?(replacement.id)
    assert_not WebPushSubscription.exists?(subscription.id)
  ensure
    release << true if release
    [ registrar, worker ].compact.each do |thread|
      thread.join(10)
      thread.kill if thread.alive?
    end
    WebPushSubscription.where(session_id: [ old_session&.id, new_session&.id ].compact).destroy_all
    [ old_session, new_session ].compact.each(&:destroy!)
    user&.update!(preferences: original_preferences) if original_preferences
  end
  test "simultaneous registrations cannot exceed the per-user device limit" do
    user = users(:family_admin)
    session = user.sessions.create!
    19.times { |i| register_web_push(user: user, session: session, endpoint: "https://fcm.googleapis.com/cap-existing-#{i}") }
    start = Queue.new
    results = Queue.new
    workers = 2.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          register_web_push(user: User.find(user.id), session: Session.find(session.id), endpoint: "https://fcm.googleapis.com/cap-concurrent-#{i}")
          results << :registered
        rescue ActiveRecord::RecordInvalid
          results << :limited
        rescue => error
          results << error
        end
      end
    end
    2.times { start << true }
    workers.each { |worker| assert worker.join(10), "Registration must finish without a lock cycle" }
    outcomes = 2.times.map { results.pop }
    assert_equal 1, outcomes.count(:registered), outcomes.inspect
    assert_equal 1, outcomes.count(:limited), outcomes.inspect
    assert_equal 20, user.web_push_subscriptions.count
  ensure
    workers&.each do |worker|
      worker.join(10)
      worker.kill if worker.alive?
    end
    session&.destroy!
  end
end
