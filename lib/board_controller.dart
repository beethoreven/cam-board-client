import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

import 'services/board_advertiser.dart';
import 'services/lan_address_finder.dart';
import 'services/name_store.dart';
import 'services/signal_server.dart';

/// 看板端的流程：把 core 的規則（[BoardSession]）接上廣播、伺服器和儲存。
class BoardController extends ChangeNotifier {
  BoardController({
    required this._advertiser,
    required this._server,
    required this._nameStore,
    required this._findAddress,
  });

  final BoardAdvertiser _advertiser;
  final SignalServer _server;
  final NameStore _nameStore;
  final LanAddressFinder _findAddress;
  final BoardSession _session = BoardSession();

  BoardState get state => _session.state;

  /// 註冊時取的名字；沒註冊時是 null。
  String? get boardName => _session.name;

  /// 給鄉民端手動輸入的位址，例如 `192.168.43.1:47800`。
  /// 沒註冊，或手機沒連上任何區域網路時是 null。
  String? get address => _address;
  String? _address;

  /// 上一次操作失敗的原因，可以直接顯示。沒有失敗時是 null。
  String? get error => _error;
  String? _error;

  /// 正在註冊或撤銷中。這段時間按鈕要停用，避免重複觸發。
  bool get busy => _busy;
  bool _busy = false;

  /// 上次用的名字，用來預先填進輸入框。
  Future<String?> loadSavedName() => _nameStore.load();

  /// 註冊看板：檢查名字 → 開始接受連線 → 開始廣播。
  /// 任何一步失敗都會退回未註冊，不會停在一半。
  Future<void> register(String name) async {
    if (_busy || state != BoardState.unregistered) return;
    _error = null;
    try {
      _session.register(name);
    } on BoardNameException catch (e) {
      _error = e.message;
      notifyListeners();
      return;
    }

    _busy = true;
    notifyListeners();
    try {
      final port = await _server.start(boardName: _session.name!);
      await _advertiser.start(name: _session.name!, port: port);
      final host = await _findAddress();
      _address = host == null ? null : '$host:$port';
      await _nameStore.save(_session.name!);
    } catch (_) {
      await _tearDown();
      _error = '註冊失敗，請確認手機已經連上 Wi-Fi 或開啟熱點';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 撤銷註冊：從看板清單上消失，回到輸入名字的畫面。
  Future<void> unregister() async {
    if (_busy || state == BoardState.unregistered) return;
    _busy = true;
    notifyListeners();
    await _tearDown();
    _busy = false;
    notifyListeners();
  }

  Future<void> _tearDown() async {
    // 兩個都要停，其中一個出錯不能讓另一個留著。
    try {
      await _advertiser.stop();
    } catch (_) {}
    try {
      await _server.stop();
    } catch (_) {}
    _session.unregister();
    _address = null;
  }

  @override
  void dispose() {
    _advertiser.stop();
    _server.stop();
    super.dispose();
  }
}
