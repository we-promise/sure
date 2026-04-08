class IndianBondsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :face_value, :coupon_rate, :maturity_date, :isin, :rating, :interest_frequency
end
