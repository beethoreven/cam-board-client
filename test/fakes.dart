import 'package:cam_board_client/services/board_advertiser.dart';
import 'package:cam_board_client/services/name_store.dart';
import 'package:cam_board_client/services/signal_server.dart';

class FakeAdvertiser implements BoardAdvertiser {
  bool failOnStart = false;
  String? advertisedName;
  int? advertisedPort;

  bool get isAdvertising => advertisedName != null;

  @override
  Future<void> start({required String name, required int port}) async {
    if (failOnStart) throw Exception('廣播失敗');
    advertisedName = name;
    advertisedPort = port;
  }

  @override
  Future<void> stop() async {
    advertisedName = null;
    advertisedPort = null;
  }
}

class FakeServer implements SignalServer {
  bool failOnStart = false;
  bool running = false;

  @override
  Future<int> start({required String boardName}) async {
    if (failOnStart) throw Exception('開不了伺服器');
    running = true;
    return 47800;
  }

  @override
  Future<void> stop() async => running = false;
}

class FakeNameStore implements NameStore {
  FakeNameStore([this.saved]);

  String? saved;

  @override
  Future<String?> load() async => saved;

  @override
  Future<void> save(String name) async => saved = name;
}
