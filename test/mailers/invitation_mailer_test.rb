require "test_helper"

class InvitationMailerTest < ActionMailer::TestCase
  test "invite_email" do
    invitation = invitations(:one)

    mail = InvitationMailer.invite_email(invitation)

    assert_equal I18n.t(
      "invitation_mailer.invite_email.subject",
      inviter: invitation.inviter.display_name,
      product_name: Rails.configuration.x.product_name
    ), mail.subject
    assert_equal [ invitation.email ], mail.to
    assert_equal [ "hello@example.com" ], mail.from
    assert_match "accept", mail.body.encoded
  end
end
