import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/parse_error_type.dart';

void main() {
  group('looksLikeNetworkParseFailure', () {
    test('detects DNS and socket failures', () {
      expect(
        looksLikeNetworkParseFailure(
          "SocketException: Failed host lookup: 'parse.yorigo.kr'",
        ),
        isTrue,
      );
      expect(
        looksLikeNetworkParseFailure('ClientException: Connection closed'),
        isTrue,
      );
      expect(looksLikeNetworkParseFailure('재료 정보가 부족합니다'), isFalse);
    });
  });

  group('resolvePersistedParseErrorType', () {
    test('keeps backend cooking failures', () {
      expect(
        resolvePersistedParseErrorType(
          'socket',
          providedType: 'not_cooking',
        ),
        'not_cooking',
      );
    });

    test('rewrites generic server_error when the message is DNS', () {
      expect(
        resolvePersistedParseErrorType(
          "Failed host lookup: 'parse.yorigo.kr'",
          providedType: 'server_error',
        ),
        'network_error',
      );
    });
  });

  group('resolveDisplayedParseErrorType', () {
    test('relabels old socket rows stored as server_error', () {
      expect(
        resolveDisplayedParseErrorType(
          errorType: 'server_error',
          errorMessage: "SocketException: Failed host lookup: 'parse.yorigo.kr'",
        ),
        'network_error',
      );
    });
  });
}
