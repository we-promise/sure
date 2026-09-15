module WriteOnlyIbanParams
  extend ActiveSupport::Concern

  private
    # accounts/_form.html.erb and family_merchants/_form.html.erb never
    # pre-fill the iban field with the stored (decrypted) value -- so on
    # update, a submit with the field left blank must mean "the user didn't
    # touch it," not "clear it," or every edit that doesn't retype the IBAN
    # would silently wipe it. clear_flag (an explicit "remove IBAN" checkbox,
    # only rendered once a value is already stored) is the only way to
    # actually clear it.
    def resolve_write_only_iban(params_hash, clear_flag:)
      params_hash = params_hash.to_h
      if ActiveModel::Type::Boolean.new.cast(clear_flag)
        params_hash[:iban] = nil
      elsif params_hash[:iban].blank?
        params_hash.delete(:iban)
      end
      params_hash
    end
end
