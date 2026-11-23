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
}

/// 用 mDNS（Bonjour）廣播。
class BonsoirBoardAdvertiser implements BoardAdvertiser {
  BonsoirBroadcast? _broadcast;

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
    await broadcast.start();
    _broadcast = broadcast;
  }

  @override
  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    await broadcast?.stop();
  }
}
