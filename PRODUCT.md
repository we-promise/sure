# Product

## Register

product

## Users

Brazilian individuals managing personal finances in BRL. Typical session: checking account balances, categorizing recent transactions, reviewing spending against a budget, or looking up investment positions. Not financial experts by default; willing to engage deeply once the interface earns their trust. Using on a laptop or phone, usually during a few minutes of attention between other tasks.

## Product Purpose

Finantreta is a personal fork of Sure (the community-maintained fork of Maybe Finance) customized for the Brazilian context: bank catalog with ISPB codes, BRL-native account kinds, and eventual deeper integration with Brazilian financial infrastructure (Open Finance, Pix, etc.). Success looks like a Brazilian user being able to set up their accounts, link their actual banks, and have a clear picture of where their money goes, without any friction from currency, bank, or locale mismatch.

## Brand Personality

Bold, honest, uncluttered. Not the aggressive boldness of a fintech startup seeking VC attention, but the confidence of something that knows exactly what it is and does it well. Voice is direct without being terse, approachable without being cute.

Three words: **clear, capable, grounded**.

## Anti-references

- **Spreadsheet UIs**: dense tables with no visual hierarchy, every cell carrying equal weight. Information should breathe. Scanning for a number should take one second, not ten.
- **Bank apps (Itaú, Bradesco)**: stiff, corporate, designed for compliance rather than users. Every action buried three taps deep.
- **Generic fintech cliché**: navy background, gold accent, dashboard widgets with oversized numbers and gradient rings. The category-reflex trap.

## Design Principles

1. **Information hierarchy over information density.** Show the number that matters at the size it deserves. Everything else recedes until needed.
2. **Brazilian-native, not translated.** BRL amounts, Brazilian bank names, Brazilian date conventions. Not an afterthought, not a locale flag.
3. **Calm confidence.** Bold design choices executed quietly. No decorative animation, no performative complexity.
4. **Trust through clarity.** Financial data is sensitive. The UI should feel precise and intentional, not generic.
5. **Progressive disclosure.** The overview is always legible at a glance. Detail is one deliberate interaction away.

## Accessibility & Inclusion

WCAG AA minimum. High contrast ratios for financial figures (anything carrying a monetary value). Support reduced motion via `prefers-reduced-motion`. Ensure all interactive elements are keyboard-navigable. Avoid relying on color alone to convey meaning (e.g., gains/losses must also use sign or label).
