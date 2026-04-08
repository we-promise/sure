class IndianRealEstatesController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :area_value, :area_unit, :registration_number, :property_type_classification, address_attributes: [ :id, :line1, :line2, :city, :state, :postal_code, :country ]
end
