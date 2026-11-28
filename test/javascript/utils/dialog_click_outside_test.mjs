import assert from "node:assert/strict";
import { test } from "node:test";
import { shouldCloseOnClick } from "../../../app/javascript/utils/dialog_click_outside.mjs";

// Minimal stand-in for the dialog's content element.
const content = (...inside) => ({ contains: (node) => inside.includes(node) });
const inside = {};
const outside = {};

test("closes when the press and the click both happen outside the content", () => {
  assert.equal(shouldCloseOnClick(outside, outside, content(inside)), true);
});

test("does not close when both happen inside the content", () => {
  assert.equal(shouldCloseOnClick(inside, inside, content(inside)), false);
});

test("does not close when a text selection starts inside and is released outside", () => {
  assert.equal(shouldCloseOnClick(inside, outside, content(inside)), false);
});

test("closes when there was no tracked press (e.g. keyboard-triggered click)", () => {
  assert.equal(shouldCloseOnClick(null, outside, content(inside)), true);
});
