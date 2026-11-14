# frozen_string_literal: true

require "test_helper"
require_relative "../../support/tricount_test_helper"

class Provider::TricountAdapterTest < ActiveSupport::TestCase
  include TricountTestHelper

  test "every tricount is Tricount, at tricount.com" do
    item = families(:empty).tricount_items.create!(name: "Tricount", sharing_tokens: SHARING_TOKEN)
    tricount_account = item.tricount_accounts.new
    tricount_account.upsert_from_tricount!(tricount_registry)
    adapter = Provider::TricountAdapter.new(tricount_account)

    assert_equal [ "Tricount", "tricount.com", "https://tricount.com" ], [ adapter.institution_name, adapter.institution_domain, adapter.institution_url ]
    assert_equal({ "name" => "Tricount", "domain" => "tricount.com", "url" => "https://tricount.com" }, tricount_account.institution_metadata)
  end

  test "the connections list shows Tricount's own initials, colour and domain" do
    metadata = Provider::Metadata.for(:tricount)

    assert_equal [ "TC", "tricount.com", "Tricount" ], metadata.values_at(:logo_text, :domain, :name)
    assert metadata[:logo_color].present?
  end
end
