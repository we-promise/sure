# Loads the icons found for a domain into the icon picker (accounts/_logo_field)
# of the form it sits in: the account form, or an institution's settings,
# which share the picker. Nothing is saved here.
module AccountLogoOptions
  extend ActiveSupport::Concern

  private
    # The form may hold a domain or name that is not saved yet.
    def render_logo_options(account)
      account.assign_attributes(params.permit(:institution_domain, :institution_name))
      render partial: "accounts/logo_field", locals: { account: account, candidates: Account::LogoFetcher.new(account).candidates }
    end
end
