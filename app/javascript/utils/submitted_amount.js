import evaluateAmountExpression, {
  precisionFromStep,
} from "utils/evaluate_amount_expression";

// The amount a money field submits, read from the field's own controller, so
// a number derived from it (a split balance, an exchange rate) matches what
// the server saves: rounded to the field's precision, and unrounded while the
// field's currency lookup is pending. Before that controller connects, the
// text is read and rounded to the given precision the same way.
export default function submittedAmount(
  application,
  input,
  precision = precisionFromStep(input.step),
) {
  const field = input.closest("[data-controller~='money-field']");
  const controller =
    field &&
    application.getControllerForElementAndIdentifier(field, "money-field");
  if (controller) return controller.submittedAmount();

  const amount = evaluateAmountExpression(input.value, { precision });
  if (amount === null || precision === null || precision === undefined) {
    return amount;
  }
  return Number(amount.toFixed(precision));
}
