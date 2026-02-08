# Enhanced PWA Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the basic offline fallback PWA into a full-featured Progressive Web App with app shell caching and push notifications.

**Architecture:** Implement a stale-while-revalidate caching strategy for the app shell (CSS, JS, fonts), add the webpush gem for server-side push notifications, create a PushSubscription model to store user subscriptions, and enable push notifications in the service worker.

**Tech Stack:** Rails 8, webpush gem, Web Push API, Service Worker API, Stimulus controllers

---

## Task 1: Add App Shell Caching to Service Worker

**Files:**
- Modify: `app/views/pwa/service-worker.js`

**Step 1: Update the service worker with app shell caching**

Replace the entire file content:

```javascript
const CACHE_VERSION = 'v2';
const STATIC_CACHE = `static-${CACHE_VERSION}`;
const DYNAMIC_CACHE = `dynamic-${CACHE_VERSION}`;

const OFFLINE_ASSETS = [
  '/offline.html',
  '/logo-offline.svg',
  '/logo-pwa.png'
];

const APP_SHELL_ASSETS = [
  '/',
  '/manifest'
];

// Install event - cache offline assets
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then((cache) => {
      return cache.addAll(OFFLINE_ASSETS);
    })
  );
  self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames.map((cacheName) => {
          if (cacheName !== STATIC_CACHE && cacheName !== DYNAMIC_CACHE) {
            return caches.delete(cacheName);
          }
        })
      );
    }).then(() => self.clients.claim())
  );
});

// Fetch event - network first with cache fallback for pages, cache first for assets
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // Skip non-GET requests
  if (event.request.method !== 'GET') return;

  // Skip API requests - always go to network
  if (url.pathname.startsWith('/api/')) return;

  // Handle navigation requests (pages)
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          // Cache successful responses
          if (response.ok) {
            const responseClone = response.clone();
            caches.open(DYNAMIC_CACHE).then((cache) => {
              cache.put(event.request, responseClone);
            });
          }
          return response;
        })
        .catch(() => {
          // Try cache, then offline page
          return caches.match(event.request)
            .then((cached) => cached || caches.match('/offline.html'));
        })
    );
    return;
  }

  // Handle static assets (JS, CSS, fonts, images)
  if (url.pathname.match(/\.(js|css|woff2?|png|jpg|svg|ico)$/)) {
    event.respondWith(
      caches.match(event.request).then((cached) => {
        const fetchPromise = fetch(event.request).then((response) => {
          if (response.ok) {
            const responseClone = response.clone();
            caches.open(STATIC_CACHE).then((cache) => {
              cache.put(event.request, responseClone);
            });
          }
          return response;
        });
        // Stale-while-revalidate: return cache immediately, update in background
        return cached || fetchPromise;
      })
    );
    return;
  }

  // Handle offline assets
  if (OFFLINE_ASSETS.some(asset => url.pathname === asset)) {
    event.respondWith(
      caches.match(event.request).then((response) => response || fetch(event.request))
    );
  }
});

// Push notification handler
self.addEventListener('push', (event) => {
  if (!event.data) return;

  const data = event.data.json();
  const title = data.title || 'Sure';
  const options = {
    body: data.body,
    icon: '/logo-pwa.png',
    badge: '/logo-pwa.png',
    data: { path: data.path || '/' },
    tag: data.tag || 'default',
    requireInteraction: data.requireInteraction || false
  };

  event.waitUntil(
    self.registration.showNotification(title, options)
  );
});

// Notification click handler
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const path = event.notification.data?.path || '/';

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true })
      .then((clientList) => {
        // Focus existing window if available
        for (const client of clientList) {
          if (new URL(client.url).pathname === path && 'focus' in client) {
            return client.focus();
          }
        }
        // Open new window
        if (clients.openWindow) {
          return clients.openWindow(path);
        }
      })
  );
});
```

**Step 2: Verify service worker syntax**

Run: `node -c app/views/pwa/service-worker.js`
Expected: No syntax errors

**Step 3: Commit**

```bash
git add app/views/pwa/service-worker.js
git commit -m "feat(pwa): add app shell caching and push notification handlers"
```

---

## Task 2: Add webpush Gem

**Files:**
- Modify: `Gemfile`

**Step 1: Add webpush gem to Gemfile**

Add after the existing gems (around line 70, near other utility gems):

```ruby
gem "webpush", "~> 2.0"
```

**Step 2: Install the gem**

Run: `bundle install`
Expected: Successfully installed webpush

**Step 3: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore: add webpush gem for push notifications"
```

---

## Task 3: Generate VAPID Keys Configuration

**Files:**
- Create: `config/initializers/webpush.rb`

**Step 1: Create webpush initializer**

```ruby
# frozen_string_literal: true

Rails.application.config.webpush = ActiveSupport::OrderedOptions.new

# VAPID keys for Web Push
# Generate with: Webpush.generate_key
Rails.application.config.webpush.vapid_public_key = ENV.fetch("VAPID_PUBLIC_KEY", nil)
Rails.application.config.webpush.vapid_private_key = ENV.fetch("VAPID_PRIVATE_KEY", nil)
Rails.application.config.webpush.vapid_subject = ENV.fetch("VAPID_SUBJECT", "mailto:support@example.com")

# Helper to check if push is configured
Rails.application.config.webpush.enabled = -> {
  Rails.application.config.webpush.vapid_public_key.present? &&
    Rails.application.config.webpush.vapid_private_key.present?
}
```

**Step 2: Add VAPID keys to .env.example**

Modify `.env.example` to add:

```bash
# Web Push VAPID Keys (generate with: rails runner "puts Webpush.generate_key.to_hash")
VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_SUBJECT=mailto:support@example.com
```

**Step 3: Commit**

```bash
git add config/initializers/webpush.rb .env.example
git commit -m "feat(pwa): add VAPID configuration for web push"
```

---

## Task 4: Create PushSubscription Model

**Files:**
- Create: `db/migrate/XXXXXX_create_push_subscriptions.rb`
- Create: `app/models/push_subscription.rb`
- Create: `test/models/push_subscription_test.rb`

**Step 1: Generate migration**

Run: `bin/rails generate migration CreatePushSubscriptions`

**Step 2: Write the migration**

```ruby
# frozen_string_literal: true

class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :endpoint, null: false
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false
      t.string :user_agent
      t.timestamps
    end

    add_index :push_subscriptions, :endpoint, unique: true
  end
end
```

**Step 3: Run migration**

Run: `bin/rails db:migrate`
Expected: Migration completes successfully

**Step 4: Write the failing test**

Create `test/models/push_subscription_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
  end

  test "valid push subscription" do
    subscription = PushSubscription.new(
      user: @user,
      endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
      p256dh_key: "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
      auth_key: "tBHItJI5svbpez7KI4CCXg"
    )
    assert subscription.valid?
  end

  test "requires endpoint" do
    subscription = PushSubscription.new(
      user: @user,
      p256dh_key: "key",
      auth_key: "auth"
    )
    assert_not subscription.valid?
    assert_includes subscription.errors[:endpoint], "can't be blank"
  end

  test "requires unique endpoint" do
    PushSubscription.create!(
      user: @user,
      endpoint: "https://example.com/push/123",
      p256dh_key: "key1",
      auth_key: "auth1"
    )

    duplicate = PushSubscription.new(
      user: @user,
      endpoint: "https://example.com/push/123",
      p256dh_key: "key2",
      auth_key: "auth2"
    )
    assert_not duplicate.valid?
  end
end
```

**Step 5: Run tests to verify they fail**

Run: `bin/rails test test/models/push_subscription_test.rb`
Expected: FAIL - PushSubscription model doesn't exist

**Step 6: Create the model**

Create `app/models/push_subscription.rb`:

```ruby
# frozen_string_literal: true

class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, presence: true
  validates :auth_key, presence: true

  def push_payload
    {
      endpoint: endpoint,
      keys: {
        p256dh: p256dh_key,
        auth: auth_key
      }
    }
  end
end
```

**Step 7: Run tests to verify they pass**

Run: `bin/rails test test/models/push_subscription_test.rb`
Expected: PASS

**Step 8: Add association to User model**

Modify `app/models/user.rb`, add in the associations section:

```ruby
has_many :push_subscriptions, dependent: :destroy
```

**Step 9: Commit**

```bash
git add db/migrate/*_create_push_subscriptions.rb app/models/push_subscription.rb test/models/push_subscription_test.rb app/models/user.rb
git commit -m "feat(pwa): add PushSubscription model"
```

---

## Task 5: Create Push Subscriptions API Controller

**Files:**
- Create: `app/controllers/api/v1/push_subscriptions_controller.rb`
- Modify: `config/routes.rb`
- Create: `test/controllers/api/v1/push_subscriptions_controller_test.rb`

**Step 1: Write the failing test**

Create `test/controllers/api/v1/push_subscriptions_controller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Api::V1::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @token = create_oauth_token_for(@user)
    @subscription_params = {
      subscription: {
        endpoint: "https://fcm.googleapis.com/fcm/send/test123",
        keys: {
          p256dh: "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
          auth: "tBHItJI5svbpez7KI4CCXg"
        }
      }
    }
  end

  test "create subscription with valid token" do
    assert_difference "PushSubscription.count", 1 do
      post api_v1_push_subscriptions_url,
        params: @subscription_params,
        headers: { "Authorization" => "Bearer #{@token}" },
        as: :json
    end

    assert_response :created
    assert_equal @subscription_params[:subscription][:endpoint], PushSubscription.last.endpoint
  end

  test "create subscription requires authentication" do
    post api_v1_push_subscriptions_url, params: @subscription_params, as: :json
    assert_response :unauthorized
  end

  test "delete subscription" do
    subscription = PushSubscription.create!(
      user: @user,
      endpoint: "https://example.com/push/456",
      p256dh_key: "key",
      auth_key: "auth"
    )

    assert_difference "PushSubscription.count", -1 do
      delete api_v1_push_subscription_url(subscription),
        headers: { "Authorization" => "Bearer #{@token}" }
    end

    assert_response :no_content
  end

  private

  def create_oauth_token_for(user)
    app = Doorkeeper::Application.find_or_create_by!(name: "Test App") do |a|
      a.redirect_uri = "urn:ietf:wg:oauth:2.0:oob"
      a.scopes = "read_write"
    end

    token = Doorkeeper::AccessToken.create!(
      application: app,
      resource_owner_id: user.id,
      scopes: "read_write"
    )

    token.plaintext_token
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bin/rails test test/controllers/api/v1/push_subscriptions_controller_test.rb`
Expected: FAIL - Controller doesn't exist

**Step 3: Create the controller**

Create `app/controllers/api/v1/push_subscriptions_controller.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    class PushSubscriptionsController < BaseController
      def create
        subscription = current_resource_owner.push_subscriptions.find_or_initialize_by(
          endpoint: subscription_params[:endpoint]
        )

        subscription.assign_attributes(
          p256dh_key: subscription_params.dig(:keys, :p256dh),
          auth_key: subscription_params.dig(:keys, :auth),
          user_agent: request.user_agent
        )

        if subscription.save
          render json: { id: subscription.id }, status: :created
        else
          render json: { errors: subscription.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        subscription = current_resource_owner.push_subscriptions.find(params[:id])
        subscription.destroy
        head :no_content
      end

      private

      def subscription_params
        params.require(:subscription).permit(:endpoint, keys: [ :p256dh, :auth ])
      end
    end
  end
end
```

**Step 4: Add route**

Modify `config/routes.rb`, add after the `users/me` route (around line 316):

```ruby
      # Push notification subscriptions
      resources :push_subscriptions, only: [ :create, :destroy ]
```

**Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/api/v1/push_subscriptions_controller_test.rb`
Expected: PASS

**Step 6: Commit**

```bash
git add app/controllers/api/v1/push_subscriptions_controller.rb config/routes.rb test/controllers/api/v1/push_subscriptions_controller_test.rb
git commit -m "feat(pwa): add push subscriptions API endpoint"
```

---

## Task 6: Create VAPID Public Key API Endpoint

**Files:**
- Create: `app/controllers/api/v1/push_config_controller.rb`
- Modify: `config/routes.rb`

**Step 1: Create the controller**

Create `app/controllers/api/v1/push_config_controller.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    class PushConfigController < BaseController
      skip_before_action :authenticate_request!
      skip_before_action :check_api_key_rate_limit
      skip_before_action :log_api_access

      def show
        if Rails.application.config.webpush.enabled.call
          render json: {
            enabled: true,
            vapid_public_key: Rails.application.config.webpush.vapid_public_key
          }
        else
          render json: { enabled: false }
        end
      end
    end
  end
end
```

**Step 2: Add route**

Modify `config/routes.rb`, add after push_subscriptions route:

```ruby
      # Push notification configuration (no auth required)
      get "push/config", to: "push_config#show"
```

**Step 3: Commit**

```bash
git add app/controllers/api/v1/push_config_controller.rb config/routes.rb
git commit -m "feat(pwa): add push config endpoint for VAPID public key"
```

---

## Task 7: Create PushNotificationService

**Files:**
- Create: `app/models/push_notification_service.rb`
- Create: `test/models/push_notification_service_test.rb`

**Step 1: Write the failing test**

Create `test/models/push_notification_service_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class PushNotificationServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @subscription = PushSubscription.create!(
      user: @user,
      endpoint: "https://fcm.googleapis.com/fcm/send/test",
      p256dh_key: "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
      auth_key: "tBHItJI5svbpez7KI4CCXg"
    )

    Rails.application.config.webpush.vapid_public_key = "test_public_key"
    Rails.application.config.webpush.vapid_private_key = "test_private_key"
  end

  test "sends notification to user" do
    Webpush.expects(:payload_send).once.returns(true)

    result = PushNotificationService.notify(
      user: @user,
      title: "Test",
      body: "Hello"
    )

    assert result
  end

  test "handles expired subscription" do
    Webpush.expects(:payload_send).raises(Webpush::ExpiredSubscription)

    assert_difference "PushSubscription.count", -1 do
      PushNotificationService.notify(
        user: @user,
        title: "Test",
        body: "Hello"
      )
    end
  end

  test "skips when push not configured" do
    Rails.application.config.webpush.vapid_public_key = nil

    Webpush.expects(:payload_send).never

    PushNotificationService.notify(
      user: @user,
      title: "Test",
      body: "Hello"
    )
  end
end
```

**Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/push_notification_service_test.rb`
Expected: FAIL - PushNotificationService doesn't exist

**Step 3: Create the service**

Create `app/models/push_notification_service.rb`:

```ruby
# frozen_string_literal: true

class PushNotificationService
  class << self
    def notify(user:, title:, body:, path: "/", tag: nil, require_interaction: false)
      return false unless enabled?

      user.push_subscriptions.find_each do |subscription|
        send_to_subscription(subscription, title:, body:, path:, tag:, require_interaction:)
      end

      true
    end

    def notify_all(title:, body:, path: "/", tag: nil)
      return false unless enabled?

      PushSubscription.find_each do |subscription|
        send_to_subscription(subscription, title:, body:, path:, tag:)
      end

      true
    end

    private

    def enabled?
      Rails.application.config.webpush.enabled.call
    end

    def send_to_subscription(subscription, title:, body:, path:, tag:, require_interaction: false)
      message = {
        title: title,
        body: body,
        path: path,
        tag: tag,
        requireInteraction: require_interaction
      }.compact.to_json

      Webpush.payload_send(
        message: message,
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        vapid: {
          subject: Rails.application.config.webpush.vapid_subject,
          public_key: Rails.application.config.webpush.vapid_public_key,
          private_key: Rails.application.config.webpush.vapid_private_key
        }
      )
    rescue Webpush::ExpiredSubscription, Webpush::InvalidSubscription
      subscription.destroy
    rescue Webpush::Error => e
      Rails.logger.error("Push notification failed: #{e.message}")
    end
  end
end
```

**Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/push_notification_service_test.rb`
Expected: PASS

**Step 5: Commit**

```bash
git add app/models/push_notification_service.rb test/models/push_notification_service_test.rb
git commit -m "feat(pwa): add PushNotificationService for sending notifications"
```

---

## Task 8: Add Push Notification Stimulus Controller

**Files:**
- Create: `app/javascript/controllers/push_notification_controller.js`

**Step 1: Create the Stimulus controller**

```javascript
import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="push-notification"
export default class extends Controller {
  static values = {
    configUrl: { type: String, default: "/api/v1/push/config" },
    subscribeUrl: { type: String, default: "/api/v1/push_subscriptions" }
  };

  async connect() {
    if (!this.#isSupported()) return;

    this.config = await this.#fetchConfig();
    if (!this.config?.enabled) return;

    await this.#registerServiceWorker();
  }

  async subscribe() {
    if (!this.config?.enabled) {
      console.warn("Push notifications not configured");
      return;
    }

    try {
      const permission = await Notification.requestPermission();
      if (permission !== "granted") return;

      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.#urlBase64ToUint8Array(this.config.vapid_public_key)
      });

      await this.#saveSubscription(subscription);
    } catch (error) {
      console.error("Failed to subscribe to push:", error);
    }
  }

  async unsubscribe() {
    try {
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.getSubscription();

      if (subscription) {
        await subscription.unsubscribe();
        // Optionally notify server
      }
    } catch (error) {
      console.error("Failed to unsubscribe:", error);
    }
  }

  // Private methods

  #isSupported() {
    return "serviceWorker" in navigator && "PushManager" in window;
  }

  async #fetchConfig() {
    try {
      const response = await fetch(this.configUrlValue);
      return await response.json();
    } catch {
      return null;
    }
  }

  async #registerServiceWorker() {
    try {
      await navigator.serviceWorker.register("/service-worker");
    } catch (error) {
      console.error("Service worker registration failed:", error);
    }
  }

  async #saveSubscription(subscription) {
    const token = this.#getAuthToken();
    if (!token) return;

    const response = await fetch(this.subscribeUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`
      },
      body: JSON.stringify({ subscription: subscription.toJSON() })
    });

    if (!response.ok) {
      throw new Error("Failed to save subscription");
    }
  }

  #getAuthToken() {
    // Get token from meta tag or localStorage
    const meta = document.querySelector('meta[name="api-token"]');
    return meta?.content || localStorage.getItem("api_token");
  }

  #urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
    const rawData = window.atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for (let i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }
}
```

**Step 2: Commit**

```bash
git add app/javascript/controllers/push_notification_controller.js
git commit -m "feat(pwa): add Stimulus controller for push notifications"
```

---

## Task 9: Update Manifest with Additional PWA Features

**Files:**
- Modify: `app/views/pwa/manifest.json.erb`

**Step 1: Update manifest**

```erb
{
  "name": "<%= j product_name %>",
  "short_name": "<%= j product_name %>",
  "icons": [
    {
      "src": "/logo-pwa.png",
      "type": "image/png",
      "sizes": "512x512"
    },
    {
      "src": "/logo-pwa.png",
      "type": "image/png",
      "sizes": "512x512",
      "purpose": "maskable"
    }
  ],
  "start_url": "/",
  "display": "standalone",
  "display_override": ["fullscreen", "minimal-ui"],
  "scope": "/",
  "description": "<%= j product_name %> is your personal finance assistant.",
  "theme_color": "#F9F9F9",
  "background_color": "#F9F9F9",
  "orientation": "portrait-primary",
  "categories": ["finance", "productivity"],
  "shortcuts": [
    {
      "name": "Dashboard",
      "url": "/",
      "icons": [{ "src": "/logo-pwa.png", "sizes": "96x96" }]
    },
    {
      "name": "Transactions",
      "url": "/transactions",
      "icons": [{ "src": "/logo-pwa.png", "sizes": "96x96" }]
    },
    {
      "name": "Accounts",
      "url": "/accounts",
      "icons": [{ "src": "/logo-pwa.png", "sizes": "96x96" }]
    }
  ]
}
```

**Step 2: Commit**

```bash
git add app/views/pwa/manifest.json.erb
git commit -m "feat(pwa): enhance manifest with shortcuts and categories"
```

---

## Task 10: Run Full Test Suite and Create PR

**Step 1: Run linting**

Run: `bin/rubocop -f github -a`
Expected: No offenses or auto-corrected

**Step 2: Run tests**

Run: `bin/rails test`
Expected: All tests pass

**Step 3: Build Docker image**

Run: `docker build -t sure .`
Expected: Build succeeds

**Step 4: Commit any fixes**

```bash
git add -A
git commit -m "chore: fix linting issues" --allow-empty
```

**Step 5: Create PR**

```bash
git checkout -b feat/enhanced-pwa
git push -u origin feat/enhanced-pwa
gh pr create --title "feat: Enhanced PWA with app shell caching and push notifications" --body "## Summary
- Add stale-while-revalidate caching for app shell assets (JS, CSS, fonts)
- Add Web Push notification support with VAPID keys
- Add PushSubscription model to store user subscriptions
- Add API endpoints for push subscription management
- Add PushNotificationService for sending notifications
- Add Stimulus controller for client-side push subscription
- Enhance manifest with shortcuts and categories

## New API Endpoints
- GET /api/v1/push/config - Get VAPID public key
- POST /api/v1/push_subscriptions - Subscribe to push
- DELETE /api/v1/push_subscriptions/:id - Unsubscribe

## Configuration
Set these environment variables to enable push:
- VAPID_PUBLIC_KEY
- VAPID_PRIVATE_KEY
- VAPID_SUBJECT

## Test plan
- [ ] Verify service worker caches static assets
- [ ] Verify offline page shows when disconnected
- [ ] Verify push subscription works with valid VAPID keys
- [ ] Verify notifications are received on mobile/desktop
- [ ] Run full test suite

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

Plan complete and saved to `docs/plans/2026-01-20-enhanced-pwa.md`. Two execution options:

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

Which approach?
