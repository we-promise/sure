# frozen_string_literal: true

require "test_helper"

class RedbarkAccountTest < ActiveSupport::TestCase
  setup do
    @redbark_account = redbark_accounts(:savings_account)
  end

  # Redbark's accounts endpoint does not carry institutionLogo; only the
  # connections endpoint does (see Provider::Redbark#list_connections).
  test "upsert_from_redbark! takes the institution logo from the connection" do
    @redbark_account.update_columns(institution_metadata: {})

    @redbark_account.upsert_from_redbark!(
      { id: @redbark_account.redbark_account_id, connectionId: "rb_conn_1", provider: "fiskil",
        name: "Everyday Saver", type: "savings", institutionName: "Test Bank", currency: "AUD" },
      connection_data: { id: "rb_conn_1", institutionName: "Test Bank",
                         institutionLogo: "https://example.com/logo.png", status: "active" }
    )

    assert_equal "https://example.com/logo.png", @redbark_account.reload.institution_metadata["logo"]
  end
end
