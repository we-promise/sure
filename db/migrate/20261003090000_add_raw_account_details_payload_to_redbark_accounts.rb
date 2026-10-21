# frozen_string_literal: true

# Issue #142 (L45), phase 1. `GET /v1/account-details` is the only Redbark
# endpoint that reports a loan's rate, and nothing in Sure called it. The
# response is kept per account, beside the two payloads already stored the same
# way (`raw_payload`, `raw_transactions_payload`), so the processor works from
# what the bank actually sent rather than from a value parsed at fetch time.
#
# Nullable with no backfill: an account that has never had a details fetch, and
# one whose fetch failed, are both "nothing reported" and the processor treats
# them alike.
class AddRawAccountDetailsPayloadToRedbarkAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :redbark_accounts, :raw_account_details_payload, :jsonb
    # WHEN the payload was fetched, not just what it said. A stored snapshot
    # that this sync did not refresh is last week's answer, and processing it
    # as though the bank had just reported it can record a rate change that
    # never happened -- back to a rate the user has since corrected by hand.
    add_column :redbark_accounts, :account_details_fetched_at, :datetime
  end
end
