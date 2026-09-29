/// Utility functions for text manipulation
library;

/// Truncates channel/creator names based on character type:
/// - Korean characters (Hangul): max 7 characters
/// - Other characters (alphabetic, etc.): max 15 characters
/// - If exceeds limit, adds "..." at the end
String truncateChannelName(String name) {
  if (name.isEmpty) return name;

  int koreanCount = 0;
  int otherCount = 0;
  int totalLength = 0;

  // Count Korean and other characters
  for (int i = 0; i < name.length; i++) {
    final char = name[i];
    final codeUnit = char.codeUnitAt(0);

    // Check if it's a Korean character (Hangul syllables: AC00-D7A3)
    if (codeUnit >= 0xAC00 && codeUnit <= 0xD7A3) {
      // Check if adding this Korean character would exceed the limit
      if (koreanCount >= 7) {
        // Exceeded Korean limit
        return '${name.substring(0, totalLength)}...';
      }
      koreanCount++;
    } else {
      // Check if adding this other character would exceed the limit
      if (otherCount >= 15) {
        // Exceeded other characters limit
        return '${name.substring(0, totalLength)}...';
      }
      otherCount++;
    }
    totalLength++;
  }

  // If we get here, the name is within limits
  return name;
}
