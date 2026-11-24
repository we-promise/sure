require "test_helper"

class BulkInvitationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @admin = users(:family_admin)
    @family = @admin.family
  end

  test "parses, normalizes and de-duplicates emails" do
    bulk = BulkInvitation.new(
      family: @family,
      inviter: @admin,
      role: "member",
      emails: "A@Example.com, b@example.com\n a@example.com ; \n",
      self_hosted: true
    ).process

    assert_equal %w[a@example.com b@example.com], bulk.emails.sort
    assert_equal 2, bulk.link_only
  end

  test "reports invalid entries without persisting them" do
    bulk = BulkInvitation.new(
      family: @family,
      inviter: @admin,
      role: "member",
      emails: "not-an-email, good@example.com",
      self_hosted: true
    ).process

    assert_equal 1, bulk.invalid
    assert_equal 1, bulk.link_only
    invalid = bulk.results.find { |r| r.status == :invalid }
    assert_equal "not-an-email", invalid.email
    assert_not @family.invitations.where(email: "not-an-email").exists?
  end

  test "invites an existing user's email without moving their account" do
    existing_user = users(:empty)
    original_family_id = existing_user.family_id
    assert original_family_id != @family.id

    bulk = BulkInvitation.new(
      family: @family,
      inviter: @admin,
      role: "member",
      emails: existing_user.email,
      self_hosted: true
    ).process

    # An invitation never moves an existing account; it only creates a pending
    # invitation the recipient can act on by signing up.
    assert_equal 1, bulk.link_only
    assert_equal original_family_id, existing_user.reload.family_id
    assert @family.invitations.pending.where(email: existing_user.email).exists?
  end

  test "a failed enqueue does not abort the batch and processing continues" do
    mailer = mock("mailer")
    mailer.stubs(:deliver_later)
    # First address's delivery blows up (e.g. job backend down); the second must
    # still be processed and reported.
    InvitationMailer.stubs(:invite_email).raises(StandardError.new("backend down")).then.returns(mailer)

    bulk = BulkInvitation.new(
      family: @family,
      inviter: @admin,
      role: "member",
      emails: "boom@example.com, ok@example.com",
      self_hosted: false
    ).process

    results_by_email = bulk.results.index_by(&:email)
    assert_equal :invalid, results_by_email["boom@example.com"].status
    assert_equal :sent, results_by_email["ok@example.com"].status
    assert_equal 1, bulk.invalid
    assert_equal 1, bulk.sent
    # Both invitations persist regardless of enqueue outcome, so the admin can
    # remove the failed one and retry.
    assert @family.invitations.where(email: "boom@example.com").exists?
    assert @family.invitations.where(email: "ok@example.com").exists?
  end

  test "over_limit? flags batches above the cap" do
    emails = Array.new(BulkInvitation::MAX_BULK_INVITES + 1) { |i| "person#{i}@example.com" }.join(",")

    bulk = BulkInvitation.new(family: @family, inviter: @admin, role: "member", emails: emails)

    assert bulk.over_limit?
  end

  test "over_limit? flags an oversized raw blob without parsing it" do
    emails = "x" * (BulkInvitation::MAX_RAW_INPUT_LENGTH + 1)

    bulk = BulkInvitation.new(family: @family, inviter: @admin, role: "member", emails: emails)

    assert bulk.over_limit?
    assert_empty bulk.emails
  end

  test "reports link_only and enqueues no mail when self_hosted" do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      bulk = BulkInvitation.new(
        family: @family,
        inviter: @admin,
        role: "member",
        emails: "nobody@example.com",
        self_hosted: true
      ).process

      assert_equal 1, bulk.link_only
      assert_equal 0, bulk.sent
      assert_equal :link_only, bulk.results.first.status
    end
  end
end
