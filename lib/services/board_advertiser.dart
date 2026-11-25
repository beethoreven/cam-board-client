import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:cam_board_core/cam_board_core.dart';

/// 在區域網路上廣播「這裡有一個看板」。
///
/// 用介面隔開，畫面測試才能換成假的，不需要真的網路。
abstract interface class BoardAdvertiser {
  /// 開始廣播。鄉民端會在看板清單上看到 [name]。
  Future<void> start({required String name, required int port});

  /// 停止廣播。鄉民端的清單上會消失。沒有在廣播時呼叫也不會出錯。
  Future<void> stop();

  /// 廣播途中出問題時呼叫（名稱被別人用了、廣播自己停了），訊息可以直接顯示。
  /// 不通報的話，手機上看起來一切正常，鄉民端的清單上卻找不到這個看板。
  set onProblem(void Function(String message)? handler);
}

/// 用 mDNS（Bonjour）廣播。
class BonsoirBoardAdvertiser implements BoardAdvertiser {
  BonsoirBroadcast? _broadcast;
  StreamSubscription<BonsoirBroadcastEvent>? _events;
  void Function(String message)? _onProblem;

  @override
  set onProblem(void Function(String message)? handler) => _onProblem = handler;

  @override
  Future<void> start({required String name, required int port}) async {
    await stop();
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: name,
        type: boardServiceType,
        port: port,
        attributes: {'protocol': '$protocolVersion'},
      ),
    );
    await broadcast.initialize();
    _broadcast = broadcast;
    _events = broadcast.eventStream?.listen((event) {
      // 我們自己停掉的那一次已經先把 _broadcast 清掉了，不算問題。
      if (!identical(_broadcast, broadcast)) return;
      switch (event) {
        case BonsoirBroadcastNameAlreadyExistsEvent():
          _onProblem?.call('這個名字在網路上已經有人用了，鄉民端看到的名稱可能不一樣');
        case BonsoirBroadcastStoppedEvent():
          _onProblem?.call('廣播停止了，鄉民端可能搜尋不到這個看板。請撤銷註冊後重新註冊');
        default:
          break;
      }
    });
    await broadcast.start();
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    await _events?.cancel();
    _events = null;
    await broadcast?.stop();
  }
}
