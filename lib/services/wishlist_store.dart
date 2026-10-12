import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/wish_item.dart';
import 'safe_file.dart';

/// The Wishlist's items, persisted as `tasks.json` in the app documents dir
/// — the file (and record shape, see [WishItem]) Best Music's Wishlist has
/// always used, so an update keeps every item. Writes are atomic with a
/// `.bak` of the previous content ([SafeFile]); an unreadable file falls
/// back to that backup instead of turning into an empty list.
class WishlistStore {
  WishlistStore._();

  static final WishlistStore instance = WishlistStore._();

  static const String fileName = 'tasks.json';

  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$fileName');

  /// Every record in the file, Wishlist items or not, in file order.
  Future<List<WishItem>> load() async {
    try {
      final items =
          await SafeFile.readWithRecovery(await _file(), _parse) ?? [];
      final seen = <String>{};
      for (final item in items) {
        if (!seen.add(item.uid)) {
          item.uid = WishItem.newUid();
          seen.add(item.uid);
        }
      }
      return items;
    } catch (_) {
      return <WishItem>[];
    }
  }

  /// Replaces the file's content with [items].
  Future<void> save(List<WishItem> items) async {
    await SafeFile.writeString(
        await _file(), jsonEncode([for (final i in items) i.toJson()]));
  }

  static List<WishItem> _parse(String contents) => [
        for (final e in jsonDecode(contents) as List<dynamic>)
          WishItem.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
}
