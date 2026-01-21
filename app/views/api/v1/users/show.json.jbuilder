# frozen_string_literal: true

json.user do
  json.id @user.id
  json.email @user.email
  json.first_name @user.first_name
  json.last_name @user.last_name
  json.default_period @user.default_period
  json.default_account_order @user.default_account_order
  json.theme @user.theme
end

json.family do
  json.id @family.id
  json.name @family.name
  json.currency @family.currency
  json.country @family.country
  json.locale @family.locale
  json.date_format @family.date_format
  json.timezone @family.timezone
  json.month_start_day @family.month_start_day
end
