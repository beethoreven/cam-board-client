import 'package:shared_preferences/shared_preferences.dart';

/// 記住上次用的看板名稱，下次打開不用重打。
abstract interface class NameStore {
  Future<String?> load();
  Future<void> save(String name);
}

class SharedPreferencesNameStore implements NameStore {
  static const _key = 'board_name';

  @override
  Future<String?> load() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> save(String name) async =>
      (await SharedPreferences.getInstance()).setString(_key, name);
}
