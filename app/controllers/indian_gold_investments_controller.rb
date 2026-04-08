class IndianGoldInvestmentsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :subtype, :quantity_grams, :purity, :purchase_price_per_gram, :weight_unit
end
