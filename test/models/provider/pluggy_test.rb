# frozen_string_literal: true

require "test_helper"
require "support/pluggy_helpers"

# Tests for the Pluggy SDK foundation: cached API key (2h, mutex-guarded),
# X-API-KEY auth headers, typed errors, and the 401 -> force-refresh -> retry seam.
#
# NOTE: this repo's test env uses `:null_store` (config/environments/test.rb:32),
# so caching tests swap Rails.cache to MemoryStore in setup and restore it in
# teardown (same pattern as api/v1/auth_controller_test.rb). The mocha sequencing
# below uses the idiom from test/models/assistant_test.rb
# (sequence("name") + .expects(:m).in_sequence(seq).returns(...)).
class Provider::PluggyTest < ActiveSupport::TestCase
  include PluggyHelpers

  def setup
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Rails.cache = @original_cache
  end

  test "auth_headers uses X-API-KEY not Bearer" do
    h = Provider::Pluggy.auth_headers(api_key: "abc")
    assert_equal "abc", h["X-API-KEY"]
    assert_nil h["Authorization"]
    assert_equal "application/json", h["Content-Type"]
  end

  test "api_key is cached by credential fingerprint for 2h" do
    Rails.cache.clear
    Provider::Pluggy.expects(:post).with { |path, _opts| path.end_with?("/auth") }.returns(stub_pluggy_response(code: 200, body: { apiKey: "key1" })).once
    first = Provider::Pluggy.api_key(client_id: "c", client_secret: "s")
    second = Provider::Pluggy.api_key(client_id: "c", client_secret: "s")
    assert_equal "key1", first
    assert_equal "key1", second
  end

  test "api_key force: true re-auths" do
    Rails.cache.clear
    Provider::Pluggy.stubs(:post).returns(stub_pluggy_response(code: 200, body: { apiKey: "k1" }), stub_pluggy_response(code: 200, body: { apiKey: "k2" }))
    assert_equal "k1", Provider::Pluggy.api_key(client_id: "c", client_secret: "s")
    assert_equal "k2", Provider::Pluggy.api_key(client_id: "c", client_secret: "s", force: true)
  end

  test "missing apiKey raises AuthenticationError" do
    Rails.cache.clear
    Provider::Pluggy.stubs(:post).returns(stub_pluggy_response(code: 200, body: {}))
    assert_raises(Provider::Pluggy::AuthenticationError) do
      Provider::Pluggy.api_key(client_id: "c", client_secret: "s")
    end
  end

  test "send_with_auth retries once after a stale-key 401, force-refreshing the key" do
    Rails.cache.clear
    seq = sequence("stale-key 401 refresh retry")
    # Atom A: the initial request reuses the cached key WITHOUT a forced re-auth.
    Provider::Pluggy.expects(:api_key).in_sequence(seq).with(client_id: "c", client_secret: "s", force: false).returns("stale").once
    # First attempt 401s on the stale key.
    Provider::Pluggy.expects(:get).in_sequence(seq).returns(stub_pluggy_response(code: 401, body: {}))
    # Atom B: the retry MUST force a re-auth (refresh), never reuse the stale key.
    Provider::Pluggy.expects(:api_key).in_sequence(seq).with(client_id: "c", client_secret: "s", force: true).returns("fresh").once
    # Second attempt succeeds with the fresh key.
    Provider::Pluggy.expects(:get).in_sequence(seq).returns(stub_pluggy_response(code: 200, body: { ok: true }))
    result = Provider::Pluggy.send_with_auth(:get, "/accounts", client_id: "c", client_secret: "s", query: { itemId: "x" })
    assert_equal true, result[:ok]
  end

  # Task 3: connect_token + item lifecycle. Stubs return indifferent-access
  # hashes to mirror the real `parsed` contract (see pre-flight note in
  # .superpowers/sdd/progress.md); the get_item test asserts a symbol key.
  test "connect_token posts options and returns accessToken" do
    Provider::Pluggy.stubs(:send_with_auth).with(
      :post, "/connect_token",
      client_id: "c", client_secret: "s",
      body: (kind_of String)
    ).returns({ "accessToken" => "tok-123" }.with_indifferent_access)
    token = Provider::Pluggy.connect_token(
      client_id: "c", client_secret: "s", client_user_id: "u1",
      webhook_url: "https://w", redirect_url: "https://r"
    )
    assert_equal "tok-123", token
  end

  test "connect_token raises if accessToken blank" do
    Provider::Pluggy.stubs(:send_with_auth).returns({}.with_indifferent_access)
    assert_raises(Provider::Pluggy::Error) do
      Provider::Pluggy.connect_token(client_id: "c", client_secret: "s", client_user_id: "u", webhook_url: "w", redirect_url: "r")
    end
  end

  # avoidDuplicates policy (fix for ITEM_USER_ALREADY_EXISTS after a Docker -v
  # wipe that orphans the Pluggy-side item). The SDK derives the flag from
  # `item_id` presence so callers can stay agnostic: CREATE (item_id blank) ->
  # avoidDuplicates:false lets the widget RE-BIND a surviving upstream item
  # instead of 400-ing; UPDATE (item_id present) -> true preserves the re-auth
  # dedup safety net. An explicit `avoid_duplicates:` override still wins.
  # Uses mocha's `regexp_matches` (not a bare /regex/) for the `body:` kwarg
  # so the matcher machinery — not bare-Regexp detection — handles kwargs
  # (same path as the `kind_of(String)` /connect_token stub above at l75).
  test "connect_token sends avoidDuplicates:false in CREATE mode (item_id blank) so a surviving Pluggy item re-binds instead of 400 ITEM_USER_ALREADY_EXISTS" do
    Provider::Pluggy.expects(:send_with_auth).with(
      :post, "/connect_token",
      client_id: "c", client_secret: "s",
      body: regexp_matches(/"avoidDuplicates"\s*:\s*false/)
    ).returns({ "accessToken" => "tok-create" }.with_indifferent_access)
    token = Provider::Pluggy.connect_token(
      client_id: "c", client_secret: "s", client_user_id: "u1",
      webhook_url: "https://w", redirect_url: "https://r"
    )
    assert_equal "tok-create", token
  end

  test "connect_token sends avoidDuplicates:true in UPDATE mode (item_id present) to preserve the re-auth dedup safety net" do
    Provider::Pluggy.expects(:send_with_auth).with(
      :post, "/connect_token",
      client_id: "c", client_secret: "s",
      body: regexp_matches(/"avoidDuplicates"\s*:\s*true/)
    ).returns({ "accessToken" => "tok-update" }.with_indifferent_access)
    token = Provider::Pluggy.connect_token(
      client_id: "c", client_secret: "s", client_user_id: "u1",
      webhook_url: "https://w", redirect_url: "https://r", item_id: "item-7"
    )
    assert_equal "tok-update", token
  end

  test "connect_token honors an explicit avoid_duplicates override even when item_id is blank" do
    Provider::Pluggy.expects(:send_with_auth).with(
      :post, "/connect_token",
      client_id: "c", client_secret: "s",
      body: regexp_matches(/"avoidDuplicates"\s*:\s*true/)
    ).returns({ "accessToken" => "tok-override" }.with_indifferent_access)
    token = Provider::Pluggy.connect_token(
      client_id: "c", client_secret: "s", client_user_id: "u1",
      webhook_url: "https://w", redirect_url: "https://r", avoid_duplicates: true
    )
    assert_equal "tok-override", token
  end

  test "get_item returns parsed item" do
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/items/abc", client_id: "c", client_secret: "s").returns({ "id" => "abc", "status" => "ACTIVE" }.with_indifferent_access)
    item = Provider::Pluggy.get_item(item_id: "abc", client_id: "c", client_secret: "s")
    assert_equal "ACTIVE", item[:status]
  end

  test "list_items loops through /items pages" do
    page1 = { "page" => 1, "totalPages" => 2, "results" => [ { "id" => "it-1" } ] }.with_indifferent_access
    page2 = { "page" => 2, "totalPages" => 2, "results" => [ { "id" => "it-2" } ] }.with_indifferent_access

    Provider::Pluggy.stubs(:send_with_auth)
                   .with(:get, "/items", client_id: "c", client_secret: "s", query: { page: 1, pageSize: 500, clientUserId: "u1" })
                   .returns(page1)
    Provider::Pluggy.stubs(:send_with_auth)
                   .with(:get, "/items", client_id: "c", client_secret: "s", query: { page: 2, pageSize: 500, clientUserId: "u1" })
                   .returns(page2)

    items = Provider::Pluggy.list_items(client_id: "c", client_secret: "s", client_user_id: "u1")
    assert_equal %w[it-1 it-2], items.map { |item| item[:id] }
  end

  test "latest_item_id picks the newest item by updatedAt" do
    Provider::Pluggy.stubs(:list_items).returns([
      { id: "old", updatedAt: "2024-01-01T00:00:00Z" },
      { id: "new", updatedAt: "2026-01-01T00:00:00Z" }
    ].map(&:with_indifferent_access))

    assert_equal "new", Provider::Pluggy.latest_item_id(client_id: "c", client_secret: "s", client_user_id: "u1")
  end

  test "delete_item returns true" do
    Provider::Pluggy.stubs(:send_with_auth).with(:delete, "/items/abc", client_id: "c", client_secret: "s").returns({}.with_indifferent_access)
    assert Provider::Pluggy.delete_item(item_id: "abc", client_id: "c", client_secret: "s")
  end

  # Task 4: page-based loop. Stubs return indifferent-access pages so nested
  # account hashes mirror the real `parsed` contract (with_indifferent_access
  # recurses into arrays -> result hashes are symbol-accessible).
  test "get_accounts loops pages until totalPages" do
    page1 = { "page" => 1, "totalPages" => 2, "total" => 2, "results" => [ { "id" => "a1" } ] }.with_indifferent_access
    page2 = { "page" => 2, "totalPages" => 2, "total" => 2, "results" => [ { "id" => "a2" } ] }.with_indifferent_access
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/accounts", client_id: "c", client_secret: "s", query: { itemId: "it", page: 1, pageSize: 500 }).returns(page1)
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/accounts", client_id: "c", client_secret: "s", query: { itemId: "it", page: 2, pageSize: 500 }).returns(page2)
    accounts = Provider::Pluggy.get_accounts(item_id: "it", client_id: "c", client_secret: "s")
    assert_equal %w[a1 a2], accounts.map { |a| a[:id] }
  end

  # Task 5: cursor-based loop (follows `next` until null). page_transactions is
  # stubbed; its return hashes are indifferent-access so nested txn hashes are
  # symbol-accessible, mirroring the real `parsed` contract.
  test "get_account_transactions follows cursor next until null" do
    first = { "results" => [ { "id" => "t1" } ], "next" => "cursor1" }.with_indifferent_access
    second = { "results" => [ { "id" => "t2" } ], "next" => nil }.with_indifferent_access
    Provider::Pluggy.stubs(:page_transactions).with(account_id: "ac", after: nil, client_id: "c", client_secret: "s", date_from: nil, date_to: nil).returns(first)
    Provider::Pluggy.stubs(:page_transactions).with(account_id: "ac", after: "cursor1", client_id: "c", client_secret: "s", date_from: nil, date_to: nil).returns(second)
    txns = Provider::Pluggy.get_account_transactions(account_id: "ac", client_id: "c", client_secret: "s")
    assert_equal %w[t1 t2], txns.map { |t| t[:id] }
  end

  # Pluggy `next` may be an absolute URL ("https://api.pluggy.ai/v2/transactions?after=...")
  # rather than a bare cursor token. normalize_transactions_cursor must extract the
  # `after` token so the cursor loop advances instead of echoing the full URL back as
  # `after` (which would spin forever if Pluggy keeps returning the same URL).
  test "normalize_transactions_cursor extracts after token from absolute URLs and query strings" do
    # bare token passes through unchanged
    assert_equal "cursor1", Provider::Pluggy.send(:normalize_transactions_cursor, "cursor1")
    # query-string form
    assert_equal "tok", Provider::Pluggy.send(:normalize_transactions_cursor, "?accountId=x&after=tok")
    # absolute-URL form — the regression case (previously returned the whole URL)
    assert_equal "tok", Provider::Pluggy.send(:normalize_transactions_cursor, "https://api.pluggy.ai/v2/transactions?accountId=x&after=tok")
    # cursor key as fallback
    assert_equal "c2", Provider::Pluggy.send(:normalize_transactions_cursor, "?cursor=c2")
    # blank next terminates the loop
    assert_nil Provider::Pluggy.send(:normalize_transactions_cursor, nil)
    assert_nil Provider::Pluggy.send(:normalize_transactions_cursor, "")
    # URL with no after/cursor → nil (loop terminates rather than looping on a useless cursor)
    assert_nil Provider::Pluggy.send(:normalize_transactions_cursor, "https://api.pluggy.ai/v2/transactions?accountId=x")
  end

  # Task 6: investments + investment transactions (page loop via shared paged).
  # Stubs indifferent-access so nested hashes are symbol-accessible (real contract).
  test "get_investments loops pages item-scoped" do
    page1 = { "page" => 1, "totalPages" => 2, "results" => [ { "id" => "inv1", "code" => "PETR4" } ] }.with_indifferent_access
    page2 = { "page" => 2, "totalPages" => 2, "results" => [ { "id" => "inv2", "code" => "VALE3" } ] }.with_indifferent_access
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/investments", client_id: "c", client_secret: "s", query: { itemId: "it", page: 1, pageSize: 500 }).returns(page1)
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/investments", client_id: "c", client_secret: "s", query: { itemId: "it", page: 2, pageSize: 500 }).returns(page2)
    inv = Provider::Pluggy.get_investments(item_id: "it", client_id: "c", client_secret: "s")
    assert_equal %w[inv1 inv2], inv.map { |i| i[:id] }
  end

  test "get_investment_transactions loops per-investment pages" do
    page1 = { "page" => 1, "totalPages" => 1, "results" => [ { "id" => "ta", "type" => "BUY" } ] }.with_indifferent_access
    Provider::Pluggy.stubs(:send_with_auth).with(:get, "/investments/inv1/transactions", client_id: "c", client_secret: "s", query: { page: 1, pageSize: 500 }).returns(page1)
    txns = Provider::Pluggy.get_investment_transactions(investment_id: "inv1", client_id: "c", client_secret: "s")
    assert_equal [ "ta" ], txns.map { |t| t[:id] }
  end
end
