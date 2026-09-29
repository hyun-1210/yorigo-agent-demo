import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/youtube_utils.dart';

void main() {
  group('isLandscapeYouTubeSource', () {
    test('shorts URL stays in the 1:1 player', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://www.youtube.com/shorts/YQ-HhaXMIwI',
          'width': 1920,
          'height': 1080,
          'duration_sec': 19,
        }),
        isFalse,
      );
    });

    test('is_short true stays in the 1:1 player', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/YQ-HhaXMIwI',
          'is_short': true,
          'width': 1080,
          'height': 1920,
          'duration_sec': 19,
        }),
        isFalse,
      );
    });

    test('landscape cooking clip under 3 minutes uses cinema', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/abcdEFGH123',
          'is_short': false,
          'width': 1920,
          'height': 1080,
          'duration_sec': 120,
        }),
        isTrue,
      );
    });

    test('stale is_short on landscape pixels still uses cinema', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/abcdEFGH123',
          'is_short': true,
          'width': 1920,
          'height': 1080,
          'duration_sec': 120,
        }),
        isTrue,
      );
    });

    test('portrait pixels use the shorts player', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/abcdEFGH123',
          'width': 1080,
          'height': 1920,
          'duration_sec': 45,
        }),
        isFalse,
      );
    });

    test('long video without dims uses cinema', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/abcdEFGH123',
          'duration_sec': 400,
        }),
        isTrue,
      );
    });

    test('unknown dims and duration use the shorts player', () {
      expect(
        isLandscapeYouTubeSource({
          'url': 'https://youtu.be/abcdEFGH123',
        }),
        isFalse,
      );
    });
  });

  group('isYouTubeEmbedNavigationAllowed', () {
    test('allows nocookie embed https', () {
      expect(
        isYouTubeEmbedNavigationAllowed(
          'https://www.youtube-nocookie.com/embed/YQ-HhaXMIwI',
        ),
        isTrue,
      );
    });

    test('allows about blank for dispose', () {
      expect(isYouTubeEmbedNavigationAllowed('about:blank'), isTrue);
    });

    test('blocks intent scheme even with a YouTube host', () {
      expect(
        isYouTubeEmbedNavigationAllowed(
          'intent://www.youtube.com/watch?v=YQ-HhaXMIwI#Intent;package=com.google.android.youtube;end',
        ),
        isFalse,
      );
    });

    test('blocks youtube and market app schemes', () {
      expect(isYouTubeEmbedNavigationAllowed('youtube://YQ-HhaXMIwI'), isFalse);
      expect(
        isYouTubeEmbedNavigationAllowed('market://details?id=com.google.android.youtube'),
        isFalse,
      );
    });

    test('blocks leaving to the app site', () {
      expect(
        isYouTubeEmbedNavigationAllowed('https://www.yorigo.com/'),
        isFalse,
      );
    });
  });
}
