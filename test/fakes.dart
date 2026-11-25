import 'dart:async';
import 'dart:typed_data';

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

  /// 送給每個鄉民端的二進位資料（照片），照順序記下來。
  final Map<String, List<Uint8List>> sentBytes = {};

  @override
  void sendBytes(String viewerId, Uint8List bytes) =>
      sentBytes.putIfAbsent(viewerId, () => []).add(bytes);

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

  /// 模擬這支手機的鏡頭不支援縮放、對焦、切換。
  bool controlsUnsupported = false;
  int switchCount = 0;

  /// 模擬這支手機不能直接設定對焦距離。
  bool distanceUnsupported = false;

  /// 鏡頭對焦鎖住時回報的距離。
  double? reportedDistance = 2.5;

  /// 套用過的每一組設定，照順序。
  final List<({double zoom, FocusCommand focus})> applied = [];

  /// 預覽畫面的寬高比；null 模擬還沒有畫面。
  @override
  double? previewAspectRatio;

  /// 下一次對焦要等這個完成才回報，用來模擬對焦要花時間。用過一次就清掉。
  Completer<void>? nextFocusGate;

  /// 拍照時回傳的畫面（4×2，要轉 90 度才是正的）；設成 null 模擬拍照失敗。
  RawFrame? frame = RawFrame(
    width: 4,
    height: 2,
    rotation: 90,
    i420: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
  );
  int captureCount = 0;

  List<double> get zooms => [for (final a in applied) a.zoom];
  List<FocusCommand> get focuses => [for (final a in applied) a.focus];

  /// 對焦的每一步，不含「對好焦之後自動補上的固定距離」（緊接在 [HoldFocus]
  /// 或 [PointFocus] 後面的 [DistanceFocus]）。
  List<FocusCommand> get focusSteps => [
    for (var i = 0; i < applied.length; i++)
      if (!(applied[i].focus is DistanceFocus &&
          i > 0 &&
          (applied[i - 1].focus is HoldFocus ||
              applied[i - 1].focus is PointFocus)))
        applied[i].focus,
  ];

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
  Future<void> switchCamera() async {
    _failIfUnsupported();
    switchCount++;
  }

  @override
  Future<CameraOutcome> apply({
    required double zoom,
    required FocusCommand focus,
  }) async {
    _failIfUnsupported();
    applied.add((zoom: zoom, focus: focus));
    final locked = reportedDistance;
    final gate = nextFocusGate;
    nextFocusGate = null;
    if (gate != null) await gate.future;
    return switch (focus) {
      ContinuousFocus() => const CameraOutcome(),
      DistanceFocus() when distanceUnsupported => const CameraOutcome(
        distanceSupported: false,
      ),
      DistanceFocus(:final distance) => CameraOutcome(lockedDistance: distance),
      HoldFocus() || PointFocus() => CameraOutcome(lockedDistance: locked),
    };
  }

  @override
  Future<RawFrame> captureFrame() async {
    captureCount++;
    final data = frame;
    if (data == null) throw Exception('拍照失敗');
    return data;
  }

  void _failIfUnsupported() {
    if (controlsUnsupported) throw Exception('這支手機的鏡頭不支援');
  }

  @override
  Widget buildPreview() =>
      const ColoredBox(color: Color(0xFF222222), child: SizedBox.expand());
}

class FakeLink implements ViewerLink {
  void Function(CandidateMessage)? _onCandidate;
  void Function()? _onCandidatesDone;
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

  @override
  set onCandidatesDone(void Function() handler) => _onCandidatesDone = handler;

  /// 模擬這條連線的網路路徑全部找完了。
  void emitCandidatesDone() => _onCandidatesDone?.call();

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
  Future<void> join(
    String viewerId, {
    int protocol = protocolVersion,
    String name = '',
  }) async {
    server.receive(viewerId, JoinMessage(protocol: protocol, name: name));
    await pumpEventQueue();
  }

  /// 模擬一個鄉民端加入並開始抄錄。
  Future<void> joinRecording(String viewerId, {String name = ''}) async {
    await join(viewerId, name: name);
    server.receive(viewerId, const RecordStartMessage());
    await pumpEventQueue();
  }
}

/// 等所有排隊中的非同步工作做完。
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);
