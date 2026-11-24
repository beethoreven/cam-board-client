import 'package:wakelock_plus/wakelock_plus.dart';

/// 讓手機螢幕保持恆亮。看板端架著拍的時候，螢幕關掉鏡頭就會停。
abstract interface class ScreenAwake {
  Future<void> enable();
  Future<void> disable();
}

class WakelockScreenAwake implements ScreenAwake {
  @override
  Future<void> enable() => WakelockPlus.enable();

  @override
  Future<void> disable() => WakelockPlus.disable();
}
