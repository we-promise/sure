# Processes a batch of email addresses into individual Invitations, reusing the
# same per-email rules as InvitationsController#create (duplicate guards,
# cross-family guard, existing-user auto-add, and mailing). Collects a
# per-email report so the caller can summarize and export the outcome.
class BulkInvitation
  Result = Struct.new(:email, :status, :detail, keyword_init: true)

  # Splits the raw textarea on commas, semicolons and any whitespace (incl.
  # newlines), downcases/strips, drops blanks, and de-duplicates the batch.
  EMAIL_SEPARATORS = /[,;\s]+/

  attr_reader :family, :inviter, :role, :emails, :results

  def initialize(family:, inviter:, role:, emails:, self_hosted: false)
    @family = family
    @inviter = inviter
    @role = role
    @self_hosted = self_hosted
    @emails = parse_emails(emails)
    @results = []
  end

  def process
    @results = emails.map { |email| invite(email) }
    self
  end

  def sent
    count(:sent)
  end

  def added
    count(:added)
  end

  def skipped
    results.count { |r| r.status == :skipped_has_family_data }
  end

  def invalid
    count(:invalid)
  end

  private

    def count(status)
      results.count { |r| r.status == status }
    end

    def invite(email)
      invitation = family.invitations.build(email: email, role: role)
      invitation.inviter = inviter

      unless save_invitation(invitation)
        return Result.new(email: email, status: :invalid, detail: invitation.errors.full_messages.to_sentence)
      end

      existing_user = User.find_by(email: email)

      if existing_user && invitation.would_orphan_owned_accounts?(existing_user)
        Result.new(email: email, status: :skipped_has_family_data)
      elsif existing_user && invitation.accept_for(existing_user)
        Result.new(email: email, status: :added)
      elsif existing_user
        Result.new(email: email, status: :invalid)
      else
        InvitationMailer.invite_email(invitation).deliver_later unless @self_hosted
        Result.new(email: email, status: :sent)
      end
    end

    # Mirrors InvitationsController#save_invitation: a raced partial-unique-index
    # violation is treated as an ordinary save failure rather than a 500.
    def save_invitation(invitation)
      invitation.save
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def parse_emails(raw)
      raw.to_s
         .split(EMAIL_SEPARATORS)
         .map { |e| e.strip.downcase }
         .reject(&:blank?)
         .uniq
    end
end
