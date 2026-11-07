require "test_helper"

class BulkInvitationTest < ActiveSupport::TestCase
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
    assert_equal 2, bulk.sent
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
    assert_equal 1, bulk.sent
    invalid = bulk.results.find { |r| r.status == :invalid }
    assert_equal "not-an-email", invalid.email
    assert_not @family.invitations.where(email: "not-an-email").exists?
  end

  test "adds an existing user to the family" do
    existing_user = users(:empty)
    assert existing_user.family_id != @family.id

    bulk = BulkInvitation.new(
      family: @family,
      inviter: @admin,
      role: "member",
      emails: existing_user.email,
      self_hosted: true
    ).process

    assert_equal 1, bulk.added
    assert_equal @family.id, existing_user.reload.family_id
  end

  test "does not enqueue mail when self_hosted" do
    assert_no_enqueued_jobs only: ActionMailer::MailDeliveryJob do
      BulkInvitation.new(
        family: @family,
        inviter: @admin,
        role: "member",
        emails: "nobody@example.com",
        self_hosted: true
      ).process
    end
  end
end
