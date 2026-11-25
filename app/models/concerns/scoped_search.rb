# Base for a resource's query object (Account::Search, Holding::Search...),
# the convention Transaction::Search set:
#
# - The caller passes the already-authorised relation (the one it also uses
#   for show), so authorisation stays with the caller and a search can only
#   narrow it.
# - Filters are typed attributes, already parsed by the caller (the API's
#   typed readers in Api::V1::BaseController). nil means the filter is off.
#   A search never parses input or raises on a value; an undeclared filter
#   raises ActiveModel::UnknownAttributeError.
# - One public method, `<plural>_scope`, returns the filtered relation with no
#   ordering, includes or pagination, normalising values to the column's form
#   (upcased currency, downcased ticker...).
#
#   class Holding::Search
#     include ScopedSearch
#
#     attribute :account_ids # an Array; ActiveModel ignores `array: true`
#     attribute :date, :date
#
#     def holdings_scope
#       relation = scope
#       relation = relation.where(account_id: account_ids) unless account_ids.nil?
#       relation = relation.where(date:) unless date.nil?
#       relation
#     end
#   end
#
#   Holding::Search.new(accessible_holdings, filters: { date: date_filter_param(:date) }).holdings_scope
module ScopedSearch
  extend ActiveSupport::Concern

  include ActiveModel::Model
  include ActiveModel::Attributes

  def initialize(scope, filters: {})
    @scope = scope
    super(filters)
  end

  private
    attr_reader :scope
end
