# Unified Markdown Parser for Localized Strings

**Date:** 2026-06-22
**Status:** Approved — implementing
**Branch:** `michal/unified-markdown-parser`

## Problem

Localized strings carry inline styling using Apple's **proprietary** custom-attribute
markdown syntax:

```
^[Warning:](style: 'boldPrimary') Your funds cannot be spent until your wallet is restored.
```

This `^[text](style: '...')` form is an Apple-only extension parsed by
`AttributedString(markdown:including:\.zashiApp)`, where `ZashiTextAttribute` conforms to
`MarkdownDecodableAttributedStringKey` ([ZashiText.swift](../../../secant/Sources/UIComponents/Text/ZashiText.swift)).
It cannot be shared with Android.

**Goal:** unify the markdown used in localized strings with Android by replacing the
Apple-specific mechanism with a self-contained, hand-written parser that understands a
small, standard-markdown-based grammar shared by both platforms.

## Why this is a contained change

Parsing and rendering are already separate concerns:

- **Parse** (the part we replace): turn marked-up text into *semantic* style attributes
  (`zStyle == .boldPrimary`). Today done by Apple's markdown parser via the
  `MarkdownDecodableAttributedStringKey` hook.
- **Render** (`ZashiText.annotateStyle`, unchanged): walk runs and resolve each semantic
  `zStyle` to concrete SwiftUI font / color / underline using runtime context
  (`colorScheme`, `textColor`, `textSize`).

We swap the parse step and leave the render step alone, so visual-regression risk is low.

Investigation findings that bound the scope:

- **Only `boldPrimary` is used in static strings** — 26 markers across ~8 logical keys
  (× EN/ES, some with `%@` interpolation). No `bold`, `italic`, `boldItalic`, or link
  markers exist in `Localizable.xcstrings`.
- **No tests exist** for `ZashiText` — the parser is greenfield-testable.
- **All 11 call sites are identical**: `try? AttributedString(markdown: s, including: \.zashiApp)`
  → `ZashiText(withAttributedString:)`. They collapse to one new init.
- **Links / dynamic markdown come from outside static strings** (WhatsNew bulletpoints from
  the server; a couple of `text` params) — a cross-team coordination item, not a code problem.

Two correctness wins come for free:

- Today `try?` makes a malformed string render **nothing** (text silently vanishes). A
  hand-written parser is **total** — worst case it shows raw text.
- Apple's `AttributedString(markdown:)` collapses newlines / whitespace runs. Our parser
  preserves them exactly.

## Grammar (the shared iOS/Android contract)

| Style | Token | Standard markdown? |
|---|---|---|
| `bold` | `**text**` | ✅ |
| `italic` | `*text*` | ✅ |
| `boldItalic` | `***text***` | ✅ |
| `link` | `[text](url)` | ✅ |
| `boldPrimary` | `==text==` | ⚙️ one custom extension |

### Tokenization rules (v1)

1. **Delimiter runs.** A run of `*` of length 3/2/1 opens `boldItalic`/`bold`/`italic`. A run
   of exactly two `=` opens `boldPrimary`. An opener is matched by the **next identical run**
   (same character, same length) later in the input.
2. **Flat, no nesting.** The text inside a styled span is emitted literally — it is **not**
   re-parsed. Sequential spans at the top level are fine
   (`==Warning:== text [docs](url) more`); true nesting (emphasis inside a link, bold inside
   italic) is **out of scope for v1** and must be agreed as out of scope on Android too.
3. **Links.** `[visible text](url)` emits the visible text with both Foundation's `.link`
   attribute (the `URL`, which makes SwiftUI `Text` tappable) **and** `zStyle == .link` (which
   `annotateStyle` renders as an underline). A `[` with no matching `](url)` is literal.
4. **Unmatched / malformed delimiters render literally.** `**bold` with no closing `**`
   produces the literal characters `**bold`. The parser never throws and never drops text.
5. **Escaping.** A backslash escapes the immediately following markdown-significant character
   (`* = [ ] ( ) \`), emitting it literally and consuming both characters. A backslash before
   any other character is literal.
6. **Whitespace & newlines are preserved verbatim.**
7. **Interpolation happens before parsing.** `String(localizable: .key(arg))` produces the
   fully-substituted string, which is then parsed. `==%@==` → `==123 ZEC==` → `boldPrimary`.
   Known limitation (shared with the old Apple path): if an interpolated value itself contains
   a delimiter character it may be mis-parsed — acceptable for v1.

### Out of scope for v1

Nested styles, block-level markdown (headings, lists, code blocks, blockquotes),
reference-style links, autolinks, and images. The grammar above is the entire supported set.

## Architecture

### New: `ZashiMarkdown` parser

`secant/Sources/UIComponents/Text/ZashiMarkdown.swift`

```swift
enum ZashiMarkdown {
    /// Parses the unified Zashi/Android markdown grammar into a semantic AttributedString.
    /// Total: never throws; unmatched markup is emitted as literal text.
    static func parse(_ input: String) -> AttributedString
}
```

A **linear scanner / state machine** (Approach A) — chosen over a regex pipeline (fragile
`*`/`**`/`***` precedence, hard to prove identical to Android) and over a non-nesting
pair-only scanner (least future-proof). The algorithm is a documented contract both platforms
implement:

```
parse(input):
    out = AttributedString("")
    i = input.startIndex
    while i < input.endIndex:
        c = input[i]
        if c == "\\" and next is escapable:
            append literal next char (plain); advance 2; continue
        if c == "[" and a "](url)" closes it:
            append visible text with .link(url) + zStyle .link; advance past ")"; continue
        if c starts a delimiter run ("*"×3/2/1 or "="×2):
            if a matching closing run exists later:
                append inner text (literal) with the run's zStyle; advance past closer; continue
            else:
                append the run's characters literally; advance past run; continue
        append c literally (plain); advance
```

Emits the existing semantic attribute, e.g. `out[range].zStyle = .boldPrimary`, using the
`AttributeScopes.ZashiAppAttributes` scope already defined in `ZashiText.swift`.

### Modified: `ZashiText.swift`

- **Drop** `MarkdownDecodableAttributedStringKey` (and the now-unneeded
  `CodableAttributedStringKey`) from `ZashiTextAttribute` — it becomes a plain
  `AttributedStringKey`. The `Value` enum, the `ZashiAppAttributes` scope, and the
  `AttributeDynamicLookup` extension stay (the parser sets `zStyle` through them).
- **Keep** `annotateStyle` unchanged — it already maps every `zStyle` case to fonts/colors,
  including the `.link` → underline case. Tappability now comes from the `.link` URL our
  parser sets (previously set by Apple's parser).
- **Add** a parsing init:

  ```swift
  init(markdown: String, colorScheme: ColorScheme, textColor: Color? = nil, textSize: CGFloat? = nil) {
      let parsed = ZashiMarkdown.parse(markdown)
      self.attributedString = ZashiText.annotateStyle(
          from: parsed, colorScheme: colorScheme, textColor: textColor, textSize: textSize)
  }
  ```

- The old `^[...](style:...)` example comment is removed. The `init(_ localizedKey:)` and
  `withAttributedString` inits are removed if no longer referenced after the call-site
  migration (verify; remove only if unused).

### Modified: 11 call sites

Each collapses from the six-line optional dance to one line, e.g.:

```swift
// before
if let attrText = try? AttributedString(markdown: someString, including: \.zashiApp) {
    ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
}
// after
ZashiText(markdown: someString, colorScheme: colorScheme)
```

Sites (all under `secant/Sources/Features/`): `WhatsNew/WhatsNewView`,
`WalletBirthday/WalletBirthdayEstimatedHeightView`, `RestoreInfo/RestoreInfoView` (passes
`textColor:`), `CoordFlows/RestoreWalletCoordFlowView`, `CoordFlows/AddKeystoneHWWalletCoordFlowView`,
`TransactionDetails/TransactionSwapComponents`, `Receive/ReceiveView`,
`ResyncWallet/ResyncWalletView`, `SwapAndPayForm/SwapComponents`, `Settings/SettingsView`,
`RecoveryPhraseDisplay/RecoveryPhraseDisplayView`.

### Modified: `Localizable.xcstrings`

Rewrite the ~8 keys containing `^[X](style: 'boldPrimary')` → `==X==` for both EN and ES
values (26 occurrences). **Only string values change — keys are untouched**, so SwiftGen
output does not change. Example:

```
"^[Warning:](style: 'boldPrimary') Your funds..."  →  "==Warning:== Your funds..."
```

### Modified: bundled WhatsNew JSON

`WhatsNewProvider` loads its content from **bundled** resources
(`Bundle.main.url(forResource:...)` in `WhatsNewProviderLiveKey`), not a remote server, so
these ship with the app and must be migrated in lockstep:
`secant/Resources/WhatsNew/whatsNew.json` (and `whatsNew_es.json`). The EN file contained two
`^[X](style: 'bold')` markers → `**X**`; the ES file had none.

## Testing

New Swift Testing suite `zodlTests/MarkdownTests/ZashiMarkdownParserTests.swift`
(`@Suite` / `@Test` / `#expect`). No global state → no `.serialized` needed. Assert on the
parsed `AttributedString` runs (`run.zStyle`, the run's substring, and `.link` URL). Cases:

- Each style in isolation: `**b**`, `*i*`, `***bi***`, `==bp==`, `[t](https://x.io)`.
- Plain text passthrough; text with no markers.
- Multiple sequential spans in one string (the real `==Warning:== ... ==under 2%== ...` shape).
- Unmatched openers → literal: `**bold`, `==x`, `[t](no-close`.
- Escaping: `\*literal\*`, `\==`, `\\`.
- Whitespace / newline preservation (multi-line info text).
- Empty input; empty span `****`, `====`.
- Interpolated-looking content: `==123 ZEC==`, `==50%==` (percent passthrough).
- Link emits both `.link` URL and `zStyle == .link`.
- Adjacent different styles: `**b**==p==`.

## Risk & coordination

- **Risk: low–medium.** Renderer untouched; parser fully unit-tested; string change is
  value-only (no SwiftGen churn).
- **Coordination (not code):**
  - Android adopts the same grammar, especially `==boldPrimary==`. This spec's Grammar
    section is the shared contract.
  - All current in-app content (localized strings + bundled WhatsNew JSON) is migrated here.
    Any *future* externally-sourced markdown (e.g. a remotely-pushed WhatsNew payload, if that
    ever exists) must emit the unified syntax; until it does, such surfaces render literally
    (no crash, no data loss — the parser is total).

## Estimate

~1–2 days of iOS work (parser + tests + 11 call-site swaps + string migration), excluding
cross-team coordination.
