/// Short dish name for compact cards. Prefers `recipe.name` over a
/// source/video title full of hashtags and marketing copy.
String recipeCardDishTitle({
  String? name,
  String? title,
  String fallback = '레시피',
}) {
  final named = (name ?? '').trim();
  if (named.isNotEmpty && !_looksLikeSourceTitle(named)) return named;
  final cleaned = _shortenSourceTitle(
    (title ?? '').trim().isNotEmpty ? title!.trim() : named,
  );
  return cleaned.isEmpty ? fallback : cleaned;
}

bool _looksLikeSourceTitle(String value) {
  return value.contains('#') || value.length > 18;
}

String _shortenSourceTitle(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  final hash = text.indexOf('#');
  if (hash > 0) text = text.substring(0, hash);
  text = text.replaceAll(RegExp(r'[#\[\]【】]'), '');
  text = text.replaceAll(
    RegExp('[\\u{1F300}-\\u{1FAFF}\\u{2600}-\\u{27BF}\\u{FE0F}]', unicode: true),
    '',
  );
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceFirst(RegExp(r'(황금비율\s*)?레시피$'), '').trim();
  text = text.replaceFirst(RegExp(r'(만드는\s*법|만들기)$'), '').trim();
  if (text.length > 16) {
    text = text.substring(0, 16).trim();
  }
  return text;
}
