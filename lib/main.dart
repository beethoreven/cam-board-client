import 'package:flutter/material.dart';

import 'board_controller.dart';
import 'screens/board_home.dart';
import 'services/board_advertiser.dart';
import 'services/lan_address_finder.dart';
import 'services/name_store.dart';
import 'services/signal_server.dart';

void main() {
  runApp(
    CamBoardApp(
      controller: BoardController(
        advertiser: BonsoirBoardAdvertiser(),
        server: WebSocketSignalServer(),
        nameStore: SharedPreferencesNameStore(),
        findAddress: findLanAddress,
      ),
    ),
  );
}

/// 看板端。
class CamBoardApp extends StatelessWidget {
  const CamBoardApp({super.key, required this.controller});

  final BoardController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '看板端',
      home: BoardHome(controller: controller),
    );
  }
}
