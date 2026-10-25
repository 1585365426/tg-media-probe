/// Soft line breaks for long filesystem paths.
///
/// Flutter's line breaker treats a run with no spaces as one unbreakable chunk
/// until it has to give up, then it cuts at an arbitrary grapheme boundary. On a
/// 375 pt screen a sandbox path such as
///
///   /var/mobile/Containers/Data/Application/25212DE5-XXXX-.../Documents/...
///
/// therefore wraps with its 36-character container UUID sliced in half, which is
/// exactly the part an operator is trying to read when checking on device that
/// the four-zone layout is correct.
///
/// Inserting a zero-width space after each separator moves every break to a real
/// hierarchy boundary. The visible glyphs are unchanged, but the character does
/// survive a copy, so [stripSoftBreaks] and the copy button on the diagnostic
/// screen both work from the original string rather than the decorated one.
library;

/// U+200B ZERO WIDTH SPACE. Renders as nothing, counts as a break opportunity.
const String kSoftBreak = '\u200B';

/// Tokens shorter than this are left alone: a short path already fits, and
/// decorating it only adds noise to the clipboard.
const int _defaultMinTokenLength = 24;

final RegExp _tokenPattern = RegExp(r'\S+');

/// Adds break opportunities after every `/` in whitespace-delimited tokens that
/// look like paths.
///
/// A token qualifies when it contains `/` and is at least [minTokenLength]
/// characters long. Everything else — plain words, short names, the text between
/// tokens — is returned untouched, so this is safe to run over free-form detail
/// strings that mix prose with a path.
String withPathBreaks(String text, {int minTokenLength = _defaultMinTokenLength}) {
  if (text.isEmpty) return text;
  return text.splitMapJoin(
    _tokenPattern,
    onMatch: (match) {
      final token = match[0]!;
      if (token.length < minTokenLength || !token.contains('/')) return token;
      // Trailing separator produces a break after the final slash; harmless,
      // the line just ends there instead of continuing.
      return token.replaceAll('/', '/$kSoftBreak');
    },
    onNonMatch: (chunk) => chunk,
  );
}

/// Removes every soft break added by [withPathBreaks].
///
/// Used to prove the round trip in tests and to hand a clean path to anything
/// that cannot tolerate invisible characters.
String stripSoftBreaks(String text) =>
    text.contains(kSoftBreak) ? text.replaceAll(kSoftBreak, '') : text;
