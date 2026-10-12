import 'dart:convert';
import 'dart:io';

import 'package:best_music/models/wish_item.dart';
import 'package:best_music/services/wishlist_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// [WishlistStore] reads and writes the `tasks.json` Best Music's Wishlist
/// has always used (BestToDo's task record shape), so an update from a
/// build of the BestToDo repo keeps every item, field for field.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('reads a BestToDo-shaped tasks.json and keeps unknown fields', () async {
    final record = {
      'schemaVersion': 2,
      'uid': 'abc',
      'title': 'Vinyl',
      'description': 'Abbey Road',
      'note': '',
      'label': 'priority-high, gift-idea',
      'createdAt': '2026-10-01T10:00:00.000',
      'completedAt': null,
      'isDone': false,
      'isWish': true,
      'dueDate': null,
      'attachments': [],
    };
    await File('${tempDir.path}/tasks.json')
        .writeAsString(jsonEncode([record]));

    final items = await WishlistStore.instance.load();
    expect(items.single.title, 'Vinyl');
    expect(items.single.isWish, isTrue);
    expect(items.single.createdAt, DateTime(2026, 10, 1, 10));

    items.single.isDone = true;
    await WishlistStore.instance.save(items);
    final written = (jsonDecode(
            await File('${tempDir.path}/tasks.json').readAsString()) as List)
        .single as Map<String, dynamic>;
    expect(written['isDone'], isTrue);
    expect(written['schemaVersion'], 2);
    expect(written['attachments'], isEmpty);
    expect(written['uid'], 'abc');
  });

  test('an unreadable file falls back to the previous save', () async {
    await WishlistStore.instance.save([WishItem(title: 'First')]);
    await WishlistStore.instance.save([WishItem(title: 'Second')]);
    await File('${tempDir.path}/tasks.json').writeAsString('{not json');

    final items = await WishlistStore.instance.load();
    expect(items.map((i) => i.title), ['First']);
  });

  test('duplicate uids are made unique', () async {
    await WishlistStore.instance.save([
      WishItem(uid: 'same', title: 'A'),
      WishItem(uid: 'same', title: 'B'),
    ]);
    final items = await WishlistStore.instance.load();
    expect(items.map((i) => i.uid).toSet(), hasLength(2));
  });
}
