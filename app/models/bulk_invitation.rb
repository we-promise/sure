# Processes a batch of email addresses into individual Invitations, reusing the
# same per-email rules as InvitationsController#create (duplicate guards,
# self-invite guard, and mailing). An invitation never moves an existing
# account, so each row is simply built, saved and mailed. Collects a per-email
# report so the caller can summarize and export the outcome.
class BulkInvitation
  Result = Struct.new(:email, :status, :detail, keyword_init: true)

  # Splits the raw textarea on commas, semicolons and any whitespace (incl.
  # newlines), downcases/strips, drops blanks, and de-duplicates the batch.
  EMAIL_SEPARATORS = /[,;\s]+/

  # Caps a single submission so one request can't enqueue an unbounded number
  # of invitations/mail jobs. Enforced before any processing begins.
  MAX_BULK_INVITES = 50

  # Rejects an oversized raw blob before it is ever split/mapped, so a huge
  # pasted string (many separators, few real addresses) can't cost full
  # parse-time allocation just to be dropped by the row cap afterwards. Sized
  # to comfortably hold MAX_BULK_INVITES max-length (RFC 5321) addresses plus
  # separators.
  MAX_RAW_INPUT_LENGTH = MAX_BULK_INVITES * 320

  attr_reader :family, :inviter, :role, :emails, :results

  def initialize(family:, inviter:, role:, emails:, self_hosted: false)
    @family = family
    @inviter = inviter
    @role = role
    @self_hosted = self_hosted
    raw = emails.to_s
    @raw_too_long = raw.length > MAX_RAW_INPUT_LENGTH
    parsed = @raw_too_long ? [] : parse_emails(raw)
    # Cap on the submitted count (pre-dedup) so a huge pasted list can't slip
    # through by collapsing to a few addresses after de-duplication.
    @submitted_count = parsed.size
    @emails = parsed.uniq
    @results = []
  end

  def over_limit?
    @raw_too_long || @submitted_count > MAX_BULK_INVITES
  end

  def process
    @results = emails.map { |email| invite(email) }
    self
  end

  def sent
    count(:sent)
  end

  def link_only
    count(:link_only)
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

      deliver_invite(invitation)
    rescue StandardError => e
      # Any unexpected persistence error (lock timeout, connection blip, etc.)
      # must not propagate out of #process and discard the results already
      # collected for earlier rows in this batch — those invitations may already
      # be committed. Report this row as failed and keep going.
      Rails.logger.error("BulkInvitation failed to process invite for #{email}: #{e.message}")
      Result.new(email: email, status: :invalid, detail: I18n.t("invitations.bulk_create.errors.processing_failed"))
    end

    # A failed enqueue (e.g. the job backend is unreachable) must not abort the
    # whole batch and discard the results already collected. The invitation is
    # persisted either way, so report it as failed and let the admin re-invite.
    #
    # On self-hosted instances no mail is enqueued, so reporting :sent would be
    # a lie — the admin has to share the invite link manually. Report :link_only
    # instead so the summary/report reflects that nothing was emailed.
    def deliver_invite(invitation)
      return Result.new(email: invitation.email, status: :link_only) if @self_hosted

      InvitationMailer.invite_email(invitation).deliver_later
      Result.new(email: invitation.email, status: :sent)
    rescue StandardError => e
      Rails.logger.error("BulkInvitation failed to enqueue invite for #{invitation.email}: #{e.message}")
      Result.new(email: invitation.email, status: :invalid, detail: I18n.t("invitations.bulk_create.errors.email_not_queued"))
    end

    # Mirrors InvitationsController#save_invitation: a raced partial-unique-index
    # violation is treated as an ordinary save failure rather than a 500.
    def save_invitation(invitation)
      invitation.save
    rescue ActiveRecord::RecordNotUnique
      false
    end

    # Returns normalized, non-blank addresses preserving order and duplicates;
    # de-duplication happens in the initializer after the raw count is recorded.
    def parse_emails(raw)
      raw.to_s
         .split(EMAIL_SEPARATORS)
         .map { |e| e.strip.downcase }
         .reject(&:blank?)
    end
end
