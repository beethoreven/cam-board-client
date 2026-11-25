import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

import 'services/board_advertiser.dart';
import 'services/camera_source.dart';
import 'services/lan_address_finder.dart';
import 'services/name_store.dart';
import 'services/screen_awake.dart';
import 'services/signal_server.dart';
import 'services/viewer_link.dart';

/// 看板端的流程：把 core 的規則（[BoardSession]）接上廣播、連線、鏡頭和儲存。
class BoardController extends ChangeNotifier {
  BoardController({
    required this._advertiser,
    required this._server,
    required this._nameStore,
    required this._findAddress,
    required this._camera,
    required this._createLink,
    required this._screenAwake,
    this._answerTimeout = answerTimeout,
    this._cameraOpenTimeout = const Duration(seconds: 10),
  }) {
    _messages = _server.messages.listen(
      (incoming) => _serial(() => _onMessage(incoming)),
    );
    _disconnections = _server.disconnections.listen(
      (viewerId) => _serial(() => _viewerGone(viewerId)),
    );
    _advertiser.onProblem = _advertisingProblem;
  }

  final BoardAdvertiser _advertiser;
  final SignalServer _server;
  final NameStore _nameStore;
  final LanAddressFinder _findAddress;
  final CameraSource _camera;
  final ViewerLinkFactory _createLink;
  final ScreenAwake _screenAwake;
  final BoardSession _session = BoardSession();
  final FocusControl _focus = FocusControl();
  final BoardRecorders _recorders = BoardRecorders();
  final _notices = StreamController<String>.broadcast();
  final Map<String, ViewerLink> _links = {};
  Timer? _tapHoldTimer;

  /// 鄉民端加入之後最多等多久它回覆連線資訊。
  final Duration _answerTimeout;
  final Map<String, Timer> _answerTimers = {};

  /// 開鏡頭最多等多久。相機服務沒回應時不能讓後面的事全部卡住。
  final Duration _cameraOpenTimeout;

  /// 鄉民端的訊息、斷線、「不給看了」、撤銷註冊，一件做完才做下一件。
  ///
  /// 處理「加入」要開鏡頭、建連線，中間會等好幾次。不排隊的話，等待的空檔裡
  /// 另一個鄉民端加入會讓鏡頭開兩次；同一個鄉民端這時斷線，它的連線會一直留著、
  /// 鏡頭也關不掉。
  Future<void> _queue = Future.value();

  Future<void> _serial(Future<void> Function() job) {
    final done = _queue.then((_) => job());
    // 一件事出錯不能讓後面的全部不做。
    _queue = done.catchError((Object e) => debugPrint('看板端處理失敗：$e'));
    return _queue;
  }

  /// 正在進行中的對焦操作數量。這段時間雙指縮放先不動鏡頭（見 [pinchUpdated]）。
  int _focusing = 0;

  /// 第幾次要求對焦。對焦要一兩秒，連點時舊的那次比較晚回報，不能蓋掉新的。
  int _focusRequest = 0;
  int _lastShotId = 0;
  late final StreamSubscription<ViewerMessage> _messages;
  late final StreamSubscription<String> _disconnections;

  BoardState get state => _session.state;

  /// 註冊時取的名字；沒註冊時是 null。
  String? get boardName => _session.name;

  /// 正在看的鄉民端數量。
  int get viewerCount => _session.viewerCount;

  /// 看板端自己看的鏡頭預覽。
  CameraSource get camera => _camera;

  /// 給鄉民端手動輸入的位址，例如 `192.168.43.1:47800`。
  /// 沒註冊，或手機沒連上任何區域網路時是 null。
  String? get address => _address;
  String? _address;
  int? _port;

  /// 上一次操作失敗的原因，可以直接顯示。沒有失敗時是 null。
  String? get error => _error;
  String? _error;

  /// 正在註冊或撤銷中。這段時間按鈕要停用，避免重複觸發。
  bool get busy => _busy;
  bool _busy = false;

  /// 目前的鏡頭縮放倍率。
  double get zoom => _zoom;
  double _zoom = minZoom;
  double _zoomAtPinchStart = minZoom;

  /// 「自動對焦」開關。每次註冊後都是開的。
  bool get autoFocus => _focus.autoFocus;

  /// 正在拍照（擷取畫面並傳給鄉民端）。這段時間再按拍照不會有作用。
  bool get shooting => _shooting;
  bool _shooting = false;

  /// 要跳出來給使用者看的提示，例如「阿明抄錄了這個內容」。
  Stream<String> get notices => _notices.stream;

  /// 上次用的名字，用來預先填進輸入框。
  Future<String?> loadSavedName() => _nameStore.load();

  /// 註冊看板：檢查名字 → 確認相機權限 → 開始接受連線 → 開始廣播。
  /// 任何一步失敗都會退回未註冊，不會停在一半。
  Future<void> register(String name) async {
    if (_busy || state != BoardState.unregistered) return;
    _error = null;
    _focus.reset();
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
      // 註冊就代表同意被看，鄉民端之後隨時可能連進來，那時不會有人在手機前
      // 按允許。所以相機權限要在註冊這一刻就確認好。
      try {
        await _camera.ensurePermission();
      } catch (_) {
        throw const _RegisterFailure('需要相機權限才能註冊');
      }
      final port = await _server.start(boardName: _session.name!);
      _port = port;
      await _advertiser.start(name: _session.name!, port: port);
      final host = await _findAddress();
      _address = host == null ? null : '$host:$port';
      await _nameStore.save(_session.name!);
      await _screenAwake.enable();
    } on _RegisterFailure catch (e) {
      await _tearDown(ByeReason.boardUnregistered);
      _error = e.message;
    } catch (e) {
      debugPrint('註冊失敗：$e');
      await _tearDown(ByeReason.boardUnregistered);
      _error = '註冊失敗，請確認手機已經連上 Wi-Fi 或開啟熱點';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 撤銷註冊：從看板清單上消失，正在看的鄉民端也一併結束。
  Future<void> unregister() async {
    if (_busy || state == BoardState.unregistered) return;
    _busy = true;
    notifyListeners();
    await _tearDown(ByeReason.boardUnregistered);
    _busy = false;
    notifyListeners();
  }

  /// 「不給看了」：所有鄉民端結束觀看，看板仍留在清單上等候。
  Future<void> stopShowing() => _serial(() async {
    if (state != BoardState.showing) return;
    await _endAllViewers(ByeReason.boardStopped);
    notifyListeners();
  });

  /// 重新找一次手機在區域網路上的位址。註冊之後換了 Wi-Fi 或開關熱點，
  /// 位址會變，畫面上顯示的要跟著變，鄉民端才有辦法手動輸入。
  Future<void> refreshAddress() async {
    final port = _port;
    if (port == null || state == BoardState.unregistered) return;
    final host = await _findAddress();
    if (_port != port) return;
    final next = host == null ? null : '$host:$port';
    if (next == _address) return;
    _address = next;
    notifyListeners();
  }

  void _advertisingProblem(String message) {
    debugPrint('廣播出問題：$message');
    if (state != BoardState.unregistered) _notices.add(message);
  }

  Future<void> switchCamera() async {
    if (!await _tryCameraControl(_camera.switchCamera)) return;
    // 換了一顆鏡頭，倍率從頭開始，鎖住的對焦距離也不能沿用。
    _zoom = minZoom;
    _tapHoldTimer?.cancel();
    notifyListeners();
    await _applyFocus(_focus.afterCameraSwitched());
  }

  /// 雙指縮放手勢開始。
  void pinchStarted() => _zoomAtPinchStart = _zoom;

  /// 雙指縮放手勢進行中。[scale] 是手勢回報的兩指距離比例。
  Future<void> pinchUpdated(double scale) async {
    final next = zoomForPinch(startZoom: _zoomAtPinchStart, scale: scale);
    if (next == _zoom) return;
    _zoom = next;
    notifyListeners();
    // 對焦還在進行中：這時送出設定會把對焦打斷（鏡頭的設定是整組換掉的），
    // 對到的距離就讀不到、也鎖不住。先記下倍率，對焦做完會一起套用。
    if (_focusing > 0) return;
    // 只改倍率，對焦維持原樣。
    await _tryCameraControl(
      () => _camera.apply(zoom: next, focus: _focus.current),
    );
  }

  /// 點一下畫面對焦。[x]、[y] 是 0 到 1 的比例。
  ///
  /// 「自動對焦」開著時，對到的位置維持 [tapFocusHold]，之後恢復自動對焦；
  /// 關著時就一直停在那裡。
  Future<void> focusAt(double x, double y) async {
    _tapHoldTimer?.cancel();
    final command = _focus.tapped(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
    if (_focus.holdingTap) {
      _tapHoldTimer = Timer(tapFocusHold, _onTapHoldExpired);
    }
    await _applyFocus(command);
  }

  void _onTapHoldExpired() {
    final command = _focus.tapHoldExpired();
    if (command != null) _applyFocus(command);
  }

  /// 切換「自動對焦」開關。關掉時對焦停在目前的位置。
  Future<void> setAutoFocus(bool on) async {
    _tapHoldTimer?.cancel();
    final command = _focus.setAutoFocus(on);
    notifyListeners();
    await _applyFocus(command);
  }

  /// 讓鏡頭照 [command] 對焦（倍率不變），並記下它鎖住的距離。
  Future<void> _applyFocus(FocusCommand command) async {
    if (!_camera.isOpen) return;
    final request = ++_focusRequest;
    _focusing++;
    try {
      await _focusOnce(request, command);
    } finally {
      _focusing--;
    }
  }

  Future<void> _focusOnce(int request, FocusCommand command) async {
    await _tryCameraControl(() async {
      final zoomAtStart = _zoom;
      var outcome = await _camera.apply(zoom: _zoom, focus: command);
      if (command is DistanceFocus && !outcome.distanceSupported) {
        // 這支手機不能直接設定對焦距離：改成對畫面中央對焦一次再鎖住。
        outcome = await _camera.apply(
          zoom: _zoom,
          focus: const PointFocus(0.5, 0.5),
        );
      }
      // 這次對焦還沒做完，使用者又做了別的對焦操作：這次的結果已經過時了。
      if (request != _focusRequest) return;
      final pin = command is ContinuousFocus
          ? null
          : _focus.locked(outcome.lockedDistance);
      // 對好焦之後把鏡頭固定在那個距離，相機才不會在畫面變動時自己重新對焦。
      // 這支手機不能直接設定距離時就維持原狀。
      if (pin != null && command is! DistanceFocus) {
        await _camera.apply(zoom: _zoom, focus: pin);
      } else if (_zoom != zoomAtStart) {
        // 對焦期間使用者縮放過：現在補上。
        await _camera.apply(zoom: _zoom, focus: _focus.current);
      }
    });
  }

  /// 「拍照」：擷取現在的畫面，傳給所有抄錄中的鄉民端。
  /// 沒有人在抄錄時不做任何事。
  Future<void> takeShot() async {
    if (_shooting || state != BoardState.showing) return;
    if (_recorders.recording.isEmpty) return;
    _shooting = true;
    notifyListeners();
    try {
      final frame = await _camera.captureFrame();
      final id = ++_lastShotId;
      // 擷取要一點時間，這段期間可能有人抄錄完了或離開了，所以傳之前再看一次。
      for (final viewerId in _recorders.recording) {
        _recorders.shotSent(viewerId, id);
        _server.send(
          viewerId,
          ShotMessage(
            id: id,
            width: frame.width,
            height: frame.height,
            rotation: frame.rotation,
          ),
        );
        _server.sendBytes(viewerId, frame.i420);
      }
    } catch (e) {
      debugPrint('拍照失敗：$e');
      _notices.add('拍照失敗');
    } finally {
      _shooting = false;
      notifyListeners();
    }
  }

  /// 執行一個鏡頭控制，回傳有沒有成功。
  ///
  /// 縮放、對焦、切換鏡頭能不能用，取決於這支手機的鏡頭。做不到時畫面照常
  /// 傳送，不能因為一個做不到的控制就讓整個觀看出錯。
  Future<bool> _tryCameraControl(Future<void> Function() control) async {
    try {
      await control();
      return true;
    } catch (e) {
      // 留一筆紀錄：套件升版後鏡頭控制失效時，原因只會出現在這裡。
      debugPrint('鏡頭控制失敗：$e');
      return false;
    }
  }

  Future<void> _onMessage(ViewerMessage incoming) async {
    final (:viewerId, :message) = incoming;
    switch (message) {
      case JoinMessage():
        await _viewerJoined(viewerId, message);
      case AnswerMessage(:final sdp):
        _answerTimers.remove(viewerId)?.cancel();
        await _links[viewerId]?.acceptAnswer(sdp);
      case CandidateMessage():
        await _links[viewerId]?.addCandidate(message);
      case RecordStartMessage():
        _recorders.started(viewerId);
      case RecordStopMessage():
        _recorders.stopped(viewerId);
      case ShotReceivedMessage(:final id):
        // 真的傳過這一張給它才算數，不然任何連著的鄉民端都能讓看板端跳出提示。
        final name = _recorders.shotConfirmed(viewerId, id);
        if (name != null) _notices.add(shotSavedNotice(name));
      case ByeMessage():
        await _viewerGone(viewerId);
      case HelloMessage() ||
          OfferMessage() ||
          CandidatesDoneMessage() ||
          ShotMessage():
        // 這幾種只會由看板端送出，鄉民端送來就忽略。
        break;
    }
  }

  Future<void> _viewerJoined(String viewerId, JoinMessage join) async {
    if (state == BoardState.unregistered || _links.containsKey(viewerId)) {
      return;
    }
    if (!join.isCompatible) {
      await _server.dismiss(viewerId, ByeReason.versionMismatch);
      return;
    }
    try {
      final wasOpen = _camera.isOpen;
      await _openCamera();
      // 鏡頭剛開：把對焦套回這次註冊期間的狀態（開關、鎖住的距離）。
      // 不等它做完：對焦最多要三秒，鄉民端等不到連線資訊會以為看板端沒回應。
      if (!wasOpen) unawaited(_applyFocus(_focus.afterCameraOpened()));
      final link = await _createLink();
      _links[viewerId] = link;
      _recorders.joined(viewerId, join.name);
      link.onCandidate = (candidate) => _server.send(viewerId, candidate);
      link.onCandidatesDone = () =>
          _server.send(viewerId, const CandidatesDoneMessage());
      link.onLost = () => _serial(() => _viewerLost(viewerId, link));
      _session.viewerJoined(viewerId);
      notifyListeners();
      _server.send(viewerId, OfferMessage(sdp: await link.createOffer()));
      _answerTimers[viewerId] = Timer(
        _answerTimeout,
        () => _serial(() => _viewerLost(viewerId, link)),
      );
    } catch (e) {
      debugPrint('鄉民端 $viewerId 加入失敗：$e');
      // 鏡頭開不了或連線建不起來：只結束這一個鄉民端，其他人不受影響。
      await _server.dismiss(viewerId, ByeReason.boardStopped);
      await _viewerGone(viewerId);
    }
  }

  Future<void> _openCamera() async {
    final opening = _camera.open();
    try {
      await opening.timeout(_cameraOpenTimeout);
    } on TimeoutException {
      // 不等了，但鏡頭之後可能還是開起來：到時沒有人在看就關掉，不能讓它一直開著。
      unawaited(
        opening.then(
          (_) => _serial(() async {
            if (_links.isEmpty) await _closeCamera();
          }),
          onError: (_) {},
        ),
      );
      rethrow;
    }
  }

  /// 一個鄉民端的畫面連線斷了，或它加入之後一直沒有回覆：告訴它結束了
  /// （它那邊可能還以為在看），再照一般的離開處理。
  Future<void> _viewerLost(String viewerId, ViewerLink link) async {
    // 排隊等到現在，這個鄉民端可能已經離開，甚至換了一條新的連線。
    if (!identical(_links[viewerId], link)) return;
    await _server.dismiss(viewerId, ByeReason.boardStopped);
    await _viewerGone(viewerId);
  }

  /// 一個鄉民端離開了。最後一個離開時關閉鏡頭、回到等候中。
  Future<void> _viewerGone(String viewerId) async {
    _answerTimers.remove(viewerId)?.cancel();
    final link = _links.remove(viewerId);
    _recorders.left(viewerId);
    _session.viewerLeft(viewerId);
    await link?.close();
    if (_links.isEmpty) await _closeCamera();
    notifyListeners();
  }

  Future<void> _endAllViewers(ByeReason reason) async {
    for (final viewerId in _session.stopShowing()) {
      await _server.dismiss(viewerId, reason);
    }
    final links = _links.values.toList();
    _links.clear();
    _recorders.clear();
    for (final timer in _answerTimers.values) {
      timer.cancel();
    }
    _answerTimers.clear();
    for (final link in links) {
      await link.close();
    }
    await _closeCamera();
  }

  Future<void> _closeCamera() async {
    _tapHoldTimer?.cancel();
    await _camera.close();
    _zoom = minZoom;
  }

  Future<void> _tearDown(ByeReason reason) => _serial(() async {
    // 每一項都要停，其中一項出錯不能讓其他的留著。
    for (final step in <Future<void> Function()>[
      () => _endAllViewers(reason),
      _advertiser.stop,
      _server.stop,
      _screenAwake.disable,
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _session.unregister();
    _address = null;
    _port = null;
  });

  @override
  void dispose() {
    _tapHoldTimer?.cancel();
    for (final timer in _answerTimers.values) {
      timer.cancel();
    }
    _advertiser.onProblem = null;
    _notices.close();
    _messages.cancel();
    _disconnections.cancel();
    _advertiser.stop();
    _server.stop();
    _camera.close();
    _screenAwake.disable();
    super.dispose();
  }
}

/// 註冊過程中，原因已經明確、可以直接顯示給使用者的失敗。
class _RegisterFailure implements Exception {
  const _RegisterFailure(this.message);

  final String message;
}
