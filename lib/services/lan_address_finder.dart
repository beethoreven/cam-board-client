import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';

/// 找出這支手機在區域網路上的位址，給鄉民端手動輸入用。找不到時回傳 null。
typedef LanAddressFinder = Future<String?> Function();

/// 讀取手機實際的網路介面。挑哪一個的規則在 core 的 [pickLanAddress]。
Future<String?> findLanAddress() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return pickLanAddress([
    for (final interface in interfaces)
      for (final address in interface.addresses)
        (interfaceName: interface.name, address: address.address),
  ]);
}
