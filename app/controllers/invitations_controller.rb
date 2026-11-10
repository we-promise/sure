class InvitationsController < ApplicationController
  skip_authentication only: :accept
  def new
    @invitation = Invitation.new
  end

  def create
    unless Current.user.admin?
      flash[:alert] = t(".failure")
      redirect_to settings_profile_path
      return
    end

    @invitation = Current.family.invitations.build(invitation_params)
    @invitation.inviter = Current.user

    # An invitation never moves an existing account; it only signs up a new
    # one. The answer is the same for any email, so admins cannot probe which
    # emails have an account.
    if save_invitation
      InvitationMailer.invite_email(@invitation).deliver_later unless self_hosted?
      flash[:notice] = t(".success")
    else
      flash[:alert] = @invitation.errors.of_kind?(:email, :own_email) ? t(".own_email") : t(".failure")
    end

    redirect_to settings_profile_path
  end

  # Bulk invites deliberately exclude the admin role: granting admin to many
  # accounts at once is a privilege-escalation risk, so admins are invited one
  # at a time through the single-invite flow.
  BULK_INVITE_ROLES = %w[member guest].freeze

  def bulk_new
    redirect_to settings_profile_path, alert: t("invitations.create.failure") unless Current.user.admin?
  end

  def bulk_create
    unless Current.user.admin?
      flash[:alert] = t("invitations.create.failure")
      redirect_to settings_profile_path
      return
    end

    unless BULK_INVITE_ROLES.include?(bulk_invitation_role)
      flash[:alert] = t(".invalid_role")
      redirect_to settings_profile_path
      return
    end

    @bulk = BulkInvitation.new(
      family: Current.family,
      inviter: Current.user,
      role: bulk_invitation_role,
      emails: bulk_invitation_params[:emails],
      self_hosted: self_hosted?
    )

    # Reject oversized batches before any invitation is created or mail is
    # queued, so a rejection can never leave partially-processed results. Checked
    # before the empty guard because an oversized raw blob parses to no emails,
    # and "too many" is the accurate reason in that case.
    if @bulk.over_limit?
      flash[:alert] = t(".too_many", max: BulkInvitation::MAX_BULK_INVITES)
      redirect_to settings_profile_path
      return
    end

    if @bulk.emails.empty?
      flash[:alert] = t(".no_emails")
      redirect_to settings_profile_path
      return
    end

    @bulk.process
    @report_text = bulk_report_text(@bulk)
    render :bulk_create
  end

  def accept
    @invitation = Invitation.find_by!(token: params[:id])

    if @invitation.pending?
      render :accept_choice, layout: "auth"
    else
      raise ActiveRecord::RecordNotFound
    end
  end

  def destroy
    unless Current.user.admin?
      flash[:alert] = t("invitations.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    @invitation = Current.family.invitations.find(params[:id])

    if @invitation.destroy
      flash[:notice] = t("invitations.destroy.success")
    else
      flash[:alert] = t("invitations.destroy.failure")
    end

    redirect_to settings_profile_path
  end

  private

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end

    def bulk_invitation_params
      params.require(:bulk_invitation).permit(:emails)
    end

    # Read role explicitly (not via permit) and validate it against
    # BULK_INVITE_ROLES before use, so role can never be mass-assigned to an
    # arbitrary/escalated value. Guard the shape: a flat (non-hash)
    # bulk_invitation param would raise TypeError on [:role], so return nil and
    # let the BULK_INVITE_ROLES check reject it with the handled flash.
    def bulk_invitation_role
      bulk = params.require(:bulk_invitation)
      bulk.is_a?(ActionController::Parameters) ? bulk[:role] : nil
    end

    def bulk_report_text(bulk)
      header = t(
        "invitations.bulk_create.summary",
        sent: bulk.sent,
        link_only: bulk.link_only,
        invalid: bulk.invalid
      )

      lines = bulk.results.map do |result|
        label = t("invitations.bulk_create.status.#{result.status}")
        detail = result.detail.present? ? " (#{result.detail})" : ""
        "#{result.email} - #{label}#{detail}"
      end

      ([ header, "" ] + lines).join("\n")
    end

    # Persist the invitation, treating a raced partial-unique-index violation as
    # an ordinary save failure. A concurrent double-submit can still slip between
    # the `no_duplicate_pending_invitation_in_family` validation and the INSERT.
    def save_invitation
      @invitation.save
    rescue ActiveRecord::RecordNotUnique
      false
    end
end
