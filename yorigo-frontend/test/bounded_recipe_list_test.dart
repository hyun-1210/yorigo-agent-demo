import 'package:flutter_test/flutter_test.dart';
import 'package:yorigo/utils/bounded_recipe_list.dart';

Map<String, dynamic> _recipe(String id) => {'id': id, 'title': 't$id'};

void main() {
  group('trimListFromFront', () {
    test('does nothing when under cap', () {
      final list = [1, 2, 3];
      expect(trimListFromFront(list, 5), 0);
      expect(list, [1, 2, 3]);
    });

    test('removes oldest items when over cap', () {
      final list = [1, 2, 3, 4, 5];
      expect(trimListFromFront(list, 3), 2);
      expect(list, [3, 4, 5]);
    });
  });

  group('appendUniqueRecipeMapsWithCap', () {
    test('dedupes by id and keeps newest window', () {
      final list = <Map<String, dynamic>>[
        for (var i = 0; i < 198; i++) _recipe('r$i'),
      ];
      appendUniqueRecipeMapsWithCap(
        list: list,
        batch: [_recipe('r198'), _recipe('r199'), _recipe('r198')],
        maxItems: 200,
      );
      expect(list.length, 200);
      expect(list.first['id'], 'r0');
      expect(list.last['id'], 'r199');
    });

    test('trims front after batch pushes over cap', () {
      final list = <Map<String, dynamic>>[
        for (var i = 0; i < 195; i++) _recipe('old$i'),
      ];
      appendUniqueRecipeMapsWithCap(
        list: list,
        batch: [
          for (var i = 0; i < 10; i++) _recipe('new$i'),
        ],
        maxItems: 200,
      );
      expect(list.length, 200);
      expect(list.first['id'], 'old5');
      expect(list.last['id'], 'new9');
    });

    test('skips empty id', () {
      final list = <Map<String, dynamic>>[];
      appendUniqueRecipeMapsWithCap(
        list: list,
        batch: [
          {'title': 'no id'},
          _recipe('ok'),
        ],
        maxItems: 10,
      );
      expect(list.length, 1);
      expect(list.single['id'], 'ok');
    });
  });
}
