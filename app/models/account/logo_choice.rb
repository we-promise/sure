# What the account form's icon picker (accounts/_logo_picker) submitted,
# given to several records at once, as an institution's settings give it to
# the institution's group (InstitutionGroup, which holds a logo as an account
# does) and each of its accounts. Each changes as saving the account form with
# that choice would change an account, except that an image is stored once:
# an upload or a picked icon becomes one blob that all of them share, and the
# stored logo of `source` (whose icon the picker showed) is shared as it is.
#
# `upload` is the uploaded file, `choice` what the picker's hidden field holds
# (Account#choose_logo: an Account::LogoFetcher key, "brandfetch", "stored"
# or "remove"); an upload wins over a choice, as in the account form.
class Account::LogoChoice
  attr_reader :upload, :choice, :source

  def initialize(upload: nil, choice: nil, source: nil)
    @upload = upload.presence
    @choice = choice.presence unless @upload
    @source = source
  end

  def present?
    upload.present? || choice.present?
  end

  # Whether the choice could not be given to any account: the picked icon
  # could not be downloaded, Brandfetch has no icon for the accounts' domain,
  # or the stored logo to share is gone.
  def not_applied?
    @not_applied == true
  end

  # Downloads a picked icon for `domain` (and the institution's `name`, which
  # the app stores search by) before any account is written: the search takes
  # seconds, too long to hold the accounts' transaction open. Call it once,
  # before #apply_to.
  def prepare(domain:, name:, family:)
    return unless fetched?

    fetcher = Account::LogoFetcher.new(Account.new(family: family, institution_domain: domain, institution_name: name))
    icon = fetcher.icon(choice)
    @attachable = fetcher.attachable(icon) if icon
    @not_applied = icon.nil?
  end

  # Sets the choice on `account` (or a group), to be saved with it. The first
  # one saved with an upload or a picked icon stores the image; those after
  # it are given that blob. A replaced or removed logo goes the way the account
  # form's goes: Active Storage purges its blob after the commit, and only once
  # no other account uses it.
  def apply_to(account)
    return unless present? && !not_applied?
    return unless set_on(account)

    # As for an icon chosen in the account form: a new domain must not
    # queue the automatic fetch that would replace it.
    account.logo_chosen = true
    @applied = true
  end

  # Call once every account was given the choice: a choice no account could
  # take counts as not applied.
  def finish
    @not_applied = true if present? && !@applied
  end

  private
    # A picked key other than Brandfetch, the stored logo or removal.
    def fetched?
      choice.present? && !choice.in?(%w[brandfetch stored remove])
    end

    # Returns whether the account could take the choice.
    def set_on(account)
      if upload || @attachable || choice == "stored"
        attach_to(account)
      elsif choice == "brandfetch"
        account.logo_selection = :brandfetch if account.brandfetch_logo_url
      elsif choice == "remove"
        account.logo = nil if account.logo.attached?
        account.logo_selection = :automatic
      end
    end

    def attach_to(account)
      if (blob = shared_blob)
        account.logo = blob unless account.logo.attached? && account.logo.blob == blob
      elsif choice == "stored"
        return false
      else
        account.logo = upload || @attachable
        @first_account = account
      end
      account.logo_selection = :automatic
    end

    # The image every account is given: the stored logo to share, else the
    # blob the first account saved stored.
    def shared_blob
      if choice == "stored"
        source&.logo&.blob if source&.logo&.attached?
      elsif @first_account&.logo&.attached? && @first_account.logo.blob.persisted?
        @first_account.logo.blob
      end
    end
end
