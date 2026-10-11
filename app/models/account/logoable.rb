# The account's icon: an uploaded or fetched logo, the Brandfetch logo for the
# institution domain, or the provider's logo, in that order unless the user
# chose Brandfetch over the stored logo.
module Account::Logoable
  extend ActiveSupport::Concern

  LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp image/vnd.microsoft.icon image/x-icon].freeze
  LOGO_MAX_SIZE = 1.megabyte

  included do
    has_one_attached :logo, dependent: :purge_later
    # Only new uploads: logos stored before this check must not block saves.
    validate :logo_is_small_raster_image, if: -> { attachment_changes.key?("logo") && logo.attached? }
    # The account sidebar is cached by the accounts' updated_at, which an
    # attachment alone does not change.
    before_save { self.updated_at = Time.current if attachment_changes.key?("logo") }

    # The account form saves more than once in one transaction (attribute
    # locks last), so the domain change is remembered until the commit.
    after_save { @institution_domain_saved = true if saved_change_to_institution_domain? }
    after_commit :fetch_logo_for_new_domain
    after_rollback { @institution_domain_saved = false }
  end

  # Set when the same save also picks an icon in the form, so an automatic
  # fetch for the new domain cannot overwrite it.
  attr_accessor :logo_chosen

  def logo_url
    if prefer_brandfetch_logo? && brandfetch_logo_url
      brandfetch_logo_url
    else
      stored_logo_url || fallback_logo_url
    end
  end

  # What shows without a stored logo, and so what removing it brings back.
  def fallback_logo_url
    brandfetch_logo_url || provider&.logo_url.presence
  end

  # A rejected upload re-rendered in the form is attached but unsaved and has no URL yet.
  def stored_logo_url
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached? && logo.blob.persisted?
  end

  def brandfetch_logo_url
    return if institution_domain.blank? || Setting.brand_fetch_client_id.blank?

    logo_size = Setting.brand_fetch_logo_size
    "https://cdn.brandfetch.io/#{institution_domain}/icon/fallback/lettermark/w/#{logo_size}/h/#{logo_size}?c=#{Setting.brand_fetch_client_id}"
  end

  # Where the stored logo came from: a favicon service, "appstore",
  # "googleplay" or "rustore", or nil for an upload.
  def logo_source
    logo.blob.metadata["logo_source"] if logo.attached?
  end

  # The Account::LogoFetcher key of the stored logo, e.g. "appstore:123".
  def logo_key
    logo.blob.metadata["logo_key"] || logo_source if logo.attached?
  end

  # Whether the stored logo is the icon with `key` for the current domain.
  # Favicon keys name only the service, so the domain it was fetched for has
  # to match too; icons stored before that was recorded carry it in their
  # filename ("tbank.ru.png").
  def stored_logo?(key)
    return false unless logo.attached? && logo_key == key

    (logo.blob.metadata["logo_domain"] || logo.filename.base) == institution_domain
  end

  def logo_auto?
    logo.attached? && logo.blob.metadata["logo_auto"] == true
  end

  # Applies the icon chosen in the account form: an Account::LogoFetcher key,
  # "brandfetch" or "stored" to switch what is shown without deleting the
  # stored logo, or "remove", which goes back to the automatic icon (the
  # fallback, and the nightly fetch). Returns false when the choice could not apply.
  def choose_logo(choice)
    case choice
    when "brandfetch" then brandfetch_logo_url.present? && update!(prefer_brandfetch_logo: true)
    when "stored" then logo.attached? && update!(prefer_brandfetch_logo: false)
    when "remove"
      logo.purge if logo.attached?
      update!(prefer_brandfetch_logo: false, updated_at: Time.current)
    else Account::LogoFetcher.new(self).fetch(source: choice)
    end
  end

  # Sure only picks logos nobody chose: an empty slot or its own earlier pick.
  def logo_auto_fetchable?
    institution_domain.present? && !prefer_brandfetch_logo? && (!logo.attached? || logo_auto?)
  end

  private
    # SVG is excluded: it can carry scripts and is not served inline anyway.
    def logo_is_small_raster_image
      unless logo.content_type.in?(LOGO_CONTENT_TYPES)
        errors.add(:logo, :invalid_content_type)
      end

      if logo.blob.byte_size > LOGO_MAX_SIZE
        errors.add(:logo, :too_large, max_size: LOGO_MAX_SIZE / 1.megabyte)
      end
    end

    def fetch_logo_for_new_domain
      domain_saved, @institution_domain_saved = @institution_domain_saved, false
      return unless domain_saved && !logo_chosen

      # A cleared override may fall back to the provider's domain.
      if institution_domain.present?
        AccountLogoFetchJob.perform_later(self)
      elsif logo_auto?
        # The automatic icon belonged to the institution that was removed.
        logo.purge_later
        touch
      end
    end
end
