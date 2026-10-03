import { platform } from "@floating-ui/dom";
import {
  getComputedStyle,
  getParentNode,
  getWindow,
  isHTMLElement,
  isLastTraversableNode,
  isTopLayer,
  isWebKit,
} from "@floating-ui/utils/dom";

// Floating UI platform tuned for panels that use `strategy: "fixed"`
// (DS::Menu and DS::Popover content).
//
// The problem
// -----------
// Floating UI picks the ancestor a fixed panel is measured against with its
// containing-block detection, and that detection counts any element with a
// `container-type` (a CSS container-query context) as a containing block for
// fixed descendants.
//
// Browsers disagree. `container-type` establishes a containing block for
// *absolutely* positioned descendants, but a `position: fixed` element is
// still laid out relative to the viewport -- only `transform`, `filter`,
// `backdrop-filter`, `perspective`, `will-change` and `contain` create a
// containing block for fixed elements.
//
// The bills list wraps its rows in a `@container` (Tailwind
// `container-type: inline-size`). So Floating UI computed the panel's
// coordinates relative to that container while the browser painted the fixed
// panel relative to the viewport. The panel landed offset by the container's
// position on the page -- "random places", sometimes off-screen (issue #3589).
//
// The fix
// -------
// Correct Floating UI's view of the world instead of moving the panel in the
// DOM. Teleporting the panel to <body> also works (fixed positioning is then
// unambiguous), but it drags the panel out of the Turbo Frame it is morphed
// with and out of the `within` scopes system tests assert against. Here the
// panel stays exactly where it is rendered; we only stop Floating UI from
// treating a `container-type`-only ancestor as the fixed containing block.

// Mirrors `@floating-ui/utils`' `isContainingBlock`, but without the
// `container-type` clause that browsers don't honor for `position: fixed`.
// Keep in sync with Floating UI (dom 1.7 / utils 0.2) if it is upgraded.
function establishesFixedContainingBlock(element) {
  const webkit = isWebKit();
  const css = getComputedStyle(element);

  const hasTransform = [
    "transform",
    "translate",
    "scale",
    "rotate",
    "perspective",
  ].some((property) => Boolean(css[property]) && css[property] !== "none");

  // WebKit does not create a containing block from filters, matching how
  // Floating UI guards these checks.
  const hasFilter =
    !webkit &&
    ((Boolean(css.backdropFilter) && css.backdropFilter !== "none") ||
      (Boolean(css.filter) && css.filter !== "none"));

  const hasWillChange = [
    "transform",
    "translate",
    "scale",
    "rotate",
    "perspective",
    "filter",
  ].some((property) => (css.willChange || "").includes(property));

  const hasContain = ["paint", "layout", "strict", "content"].some((value) =>
    (css.contain || "").includes(value),
  );

  return hasTransform || hasFilter || hasWillChange || hasContain;
}

// The containing block a `position: fixed` `element` is actually laid out
// against: the nearest ancestor that establishes one, or the viewport
// (`window`) when none does. Same traversal Floating UI uses, minus the
// `container-type` false positive.
function getFixedOffsetParent(element) {
  let node = getParentNode(element);

  while (isHTMLElement(node) && !isLastTraversableNode(node)) {
    if (establishesFixedContainingBlock(node)) return node;
    if (isTopLayer(node)) return getWindow(element);
    node = getParentNode(node);
  }

  return getWindow(element);
}

// Pass as `platform` to `computePosition({ strategy: "fixed", ... })`.
export const fixedStrategyPlatform = {
  ...platform,
  getOffsetParent: (element) => getFixedOffsetParent(element),
};
