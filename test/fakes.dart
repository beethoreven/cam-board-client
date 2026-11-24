import 'dart:async';

import 'package:cam_board_client/board_controller.dart';
import 'package:cam_board_client/services/board_advertiser.dart';
import 'package:cam_board_client/services/camera_source.dart';
import 'package:cam_board_client/services/name_store.dart';
import 'package:cam_board_client/services/screen_awake.dart';
import 'package:cam_board_client/services/signal_server.dart';
import 'package:cam_board_client/services/viewer_link.dart';
import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/widgets.dart';

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
  final _messages = StreamController<ViewerMessage>.broadcast(sync: true);
  final _disconnections = StreamController<String>.broadcast(sync: true);
  bool failOnStart = false;
  bool running = false;

  /// 送給每個鄉民端的訊息，照順序記下來。
  final Map<String, List<SignalMessage>> sent = {};

  /// 被看板端主動結束的鄉民端，以及結束的原因。
  final Map<String, ByeReason> dismissed = {};

  @override
  Stream<ViewerMessage> get messages => _messages.stream;

  @override
  Stream<String> get disconnections => _disconnections.stream;

  /// 模擬某個鄉民端送來一則訊息。
  void receive(String viewerId, SignalMessage message) =>
      _messages.add((viewerId: viewerId, message: message));

  /// 模擬某個鄉民端的連線斷了。
  void drop(String viewerId) => _disconnections.add(viewerId);

  @override
  Future<int> start({required String boardName}) async {
    if (failOnStart) throw Exception('開不了伺服器');
    running = true;
    return 47800;
  }

  @override
  void send(String viewerId, SignalMessage message) =>
      sent.putIfAbsent(viewerId, () => []).add(message);

  @override
  Future<void> dismiss(String viewerId, ByeReason reason) async =>
      dismissed[viewerId] = reason;

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

class FakeCamera implements CameraSource {
  bool permissionDenied = false;
  bool failOnOpen = false;
  int switchCount = 0;
  final List<double> zooms = [];
  final List<(double, double)> focusPoints = [];

  @override
  bool isOpen = false;

  @override
  Future<void> ensurePermission() async {
    if (permissionDenied) throw Exception('使用者拒絕相機權限');
  }

  @override
  Future<void> open() async {
    if (failOnOpen) throw Exception('鏡頭開不了');
    isOpen = true;
  }

  @override
  Future<void> close() async => isOpen = false;

  @override
  Future<void> switchCamera() async => switchCount++;

  @override
  Future<void> setZoom(double zoom) async => zooms.add(zoom);

  @override
  Future<void> focusAt(double x, double y) async => focusPoints.add((x, y));

  @override
  Widget buildPreview() =>
      const ColoredBox(color: Color(0xFF222222), child: SizedBox.expand());
}

class FakeLink implements ViewerLink {
  void Function(CandidateMessage)? _onCandidate;
  void Function()? _onLost;
  String? answer;
  final List<CandidateMessage> candidates = [];
  bool closed = false;

  @override
  set onCandidate(void Function(CandidateMessage) handler) =>
      _onCandidate = handler;

  @override
  set onLost(void Function() handler) => _onLost = handler;

  /// 模擬這條連線找到一條網路路徑。
  void emitCandidate(CandidateMessage candidate) =>
      _onCandidate?.call(candidate);

  /// 模擬這條連線中斷。
  void lose() => _onLost?.call();

  @override
  Future<String> createOffer() async => 'offer-sdp';

  @override
  Future<void> acceptAnswer(String sdp) async => answer = sdp;

  @override
  Future<void> addCandidate(CandidateMessage candidate) async =>
      candidates.add(candidate);

  @override
  Future<void> close() async => closed = true;
}

class FakeScreenAwake implements ScreenAwake {
  bool enabled = false;

  @override
  Future<void> enable() async => enabled = true;

  @override
  Future<void> disable() async => enabled = false;
}

/// 一組假服務，加上用它們建好的 [BoardController]。
class Harness {
  final advertiser = FakeAdvertiser();
  final server = FakeServer();
  final camera = FakeCamera();
  final awake = FakeScreenAwake();
  FakeNameStore store = FakeNameStore();
  String? lanAddress = '192.168.43.1';
  bool failOnCreateLink = false;

  /// 建立過的視訊連線，照建立順序。
  final List<FakeLink> links = [];

  late final BoardController controller = BoardController(
    advertiser: advertiser,
    server: server,
    nameStore: store,
    findAddress: () async => lanAddress,
    camera: camera,
    createLink: () async {
      if (failOnCreateLink) throw Exception('連線建不起來');
      final link = FakeLink();
      links.add(link);
      return link;
    },
    screenAwake: awake,
  );

  /// 模擬一個鄉民端加入，並等看板端處理完。
  Future<void> join(String viewerId, {int protocol = protocolVersion}) async {
    server.receive(viewerId, JoinMessage(protocol: protocol));
    await pumpEventQueue();
  }
}

/// 等所有排隊中的非同步工作做完。
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);
