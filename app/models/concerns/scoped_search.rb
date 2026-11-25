# Base for a resource's query object (Account::Search, Holding::Search...).
# Transaction::Search, older and shared with the web list, does not include
# it: it takes the family rather than a relation, and its web filters (dates
# included) arrive as the form's strings, so it reads those itself.
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
# - A from/to pair on one column goes through `within_range`.
#
#   class Holding::Search
#     include ScopedSearch
#
#     attribute :account_ids # an Array; ActiveModel ignores `array: true`
#     attribute :date, :date
#     attribute :start_date, :date
#     attribute :end_date, :date
#
#     def holdings_scope
#       relation = scope
#       relation = relation.where(account_id: account_ids) unless account_ids.nil?
#       relation = relation.where(date:) unless date.nil?
#       within_range(relation, :date, start_date, end_date)
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

    # `column` between `from` and `to`, both inclusive; a nil bound is open and
    # two nil bounds leave the relation as it is. `column` may be qualified
    # ("entries.date").
    def within_range(relation, column, from, to)
      return relation if from.nil? && to.nil?

      relation.where(column => from..to)
    end
end
