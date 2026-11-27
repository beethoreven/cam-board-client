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
    this._resumeGrace = resumeGrace,
    this._shotGiveUpAfter = shotGiveUpAfter,
  }) {
    _messages = _server.messages.listen((incoming) {
      final message = incoming.message;
      // 「你還在嗎」要馬上回，不排隊：排在一個正在開鏡頭的加入後面，
      // 鄉民端等不到回應會以為連線卡住了。
      if (message is PingMessage) {
        _server.send(incoming.viewerId, PongMessage(message.n));
        return;
      }
      _serial(() => _onMessage(incoming));
    });
    _disconnections = _server.disconnections.listen(
      (viewerId) => _serial(() {
        debugPrint('鄉民端 $viewerId 的連線斷了');
        return _viewerDropped(viewerId);
      }),
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

  /// 每一次觀看的代號對應到哪一位鄉民端。鄉民端的連線卡住時會開一條新的，
  /// 帶同一個代號接回來（見 core 的 `recovery.dart`）。
  final Map<String, String> _sessions = {};

  /// 鄉民端的連線斷掉之後，這麼久之內還讓它接回來。
  final Duration _resumeGrace;
  final Map<String, Timer> _graceTimers = {};

  /// 一張照片送出後這麼久還沒被確認就放棄。
  final Duration _shotGiveUpAfter;

  /// 每一張等確認的照片各一個「等太久就放棄」的計時，鍵是「鄉民端#照片編號」。
  final Map<String, Timer> _giveUpTimers = {};

  /// 上一張照片的大小，用來在拍之前估計暫存還放不放得下。
  int _lastFrameBytes = 0;

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

  /// 送出去、還沒回報收到的照片，只用來留紀錄（查「拍照沒反應」時看 logcat）。
  /// 鍵是「鄉民端#照片編號」。
  final Map<String, ({Stopwatch clock, Timer warning})> _shotTraces = {};

  /// 照片送出後這麼久還沒回報收到，就留一筆紀錄。正常情況不到一秒。
  static const _shotSlowAfter = Duration(seconds: 5);
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
      // 註冊期間鏡頭一直開著，不跟著鄉民端來去開關：少一組狀態，鄉民端加入
      // 不用等鏡頭，重建視訊連線時也不會誤關。
      try {
        await _openCamera();
      } catch (e) {
        debugPrint('開不了鏡頭：$e');
        throw const _RegisterFailure('開不了鏡頭，請關掉其他正在用相機的程式再試一次');
      }
      unawaited(_applyFocus(_focus.afterCameraOpened()));
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

  /// 回到前景時確認鏡頭還活著。App 在背景時系統可能把鏡頭收走，註冊期間鏡頭
  /// 又是一直開著的，不檢查的話之後有人來看就沒有畫面。
  ///
  /// 重開之後原本的視訊連線拿的還是舊的鏡頭畫面，不在這裡處理：鄉民端發現
  /// 畫面停住會自己要求重建（[VideoRestartMessage]），那時就會用到新的。
  Future<void> ensureCameraAlive() => _serial(() async {
    if (state == BoardState.unregistered) return;
    if (_camera.isOpen) {
      try {
        await _camera.captureFrame();
        return;
      } catch (e) {
        debugPrint('鏡頭沒有畫面了，重開：$e');
      }
    } else {
      debugPrint('鏡頭沒有開著，重開');
    }
    try {
      await _camera.close();
      await _openCamera();
      await _applyFocus(_focus.afterCameraOpened());
    } catch (e) {
      debugPrint('鏡頭重開失敗：$e');
      _notices.add('鏡頭開不了，請撤銷註冊後再註冊一次');
    }
    notifyListeners();
  });

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
    // 暫存滿了（鄉民端那邊一直沒回報）：丟掉最舊的騰出位置，新的照樣拍。
    // 正常情況下每一張十秒內不是被確認就是被放棄，滿不了；這裡是保險，
    // 不能因為暫存滿了就擋著不給拍。
    while (!_recorders.hasRoomFor(_lastFrameBytes)) {
      final dropped = _recorders.dropOldest();
      if (dropped.isEmpty) break;
      for (final lost in dropped) {
        debugPrint('暫存滿了，放棄照片 ${lost.id}（${lost.viewerId} 還沒收到）');
        final key = '${lost.viewerId}#${lost.id}';
        _giveUpTimers.remove(key)?.cancel();
        _shotTraces.remove(key)?.warning.cancel();
        _notices.add(shotLostNotice(lost.name));
      }
    }
    _shooting = true;
    notifyListeners();
    try {
      final frame = await _camera.captureFrame();
      final id = ++_lastShotId;
      _lastFrameBytes = frame.i420.length;
      // 擷取要一點時間，這段期間可能有人抄錄完了或離開了，所以傳之前再看一次。
      for (final viewerId in _recorders.recording) {
        // 畫面留著，鄉民端沒拿到時才有辦法再給一次。
        _recorders.shotSent(viewerId, id, frame);
        _sendShot(viewerId, id, frame);
        _traceShotSent(viewerId, id, frame.i420.length);
        _giveUpTimers['$viewerId#$id'] = Timer(
          _shotGiveUpAfter,
          () => _giveUpShot(viewerId, id),
        );
      }
    } catch (e) {
      debugPrint('拍照失敗：$e');
      _notices.add('拍照失敗');
    } finally {
      _shooting = false;
      notifyListeners();
    }
  }

  void _sendShot(String viewerId, int id, RawFrame frame) {
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

  /// 這張照片等太久了：不再等這位鄉民端，並告訴使用者它沒收到。
  void _giveUpShot(String viewerId, int id) {
    _giveUpTimers.remove('$viewerId#$id');
    final name = _recorders.giveUp(viewerId, id);
    if (name == null) return;
    debugPrint('照片 $id：$viewerId 一直沒回報收到，放棄');
    _shotTraces.remove('$viewerId#$id')?.warning.cancel();
    _notices.add(shotLostNotice(name));
  }

  void _cancelGiveUps([String? viewerId]) {
    final keys = _giveUpTimers.keys
        .where((key) => viewerId == null || key.startsWith('$viewerId#'))
        .toList();
    for (final key in keys) {
      _giveUpTimers.remove(key)?.cancel();
    }
  }

  void _traceShotSent(String viewerId, int id, int bytes) {
    debugPrint('照片 $id 送給 $viewerId（$bytes bytes）');
    final clock = Stopwatch()..start();
    _shotTraces['$viewerId#$id'] = (
      clock: clock,
      warning: Timer(_shotSlowAfter, () {
        debugPrint(
          '照片 $id 送給 $viewerId 已經 ${clock.elapsed.inSeconds} 秒，'
          '還沒回報收到；還在等回報的有 ${_shotTraces.keys.join('、')}',
        );
      }),
    );
  }

  void _traceShotConfirmed(String viewerId, int id) {
    final trace = _shotTraces.remove('$viewerId#$id');
    trace?.warning.cancel();
    debugPrint(
      '照片 $id：$viewerId 回報收到'
      '${trace == null ? '（沒有送過這一張）' : '，花了 ${trace.clock.elapsedMilliseconds} 毫秒'}',
    );
  }

  /// 這個鄉民端走了（[viewerId] 是 null 時是全部都走了）：它還沒回報的照片不用再等。
  void _dropShotTraces([String? viewerId]) {
    final keys = _shotTraces.keys
        .where((key) => viewerId == null || key.startsWith('$viewerId#'))
        .toList();
    for (final key in keys) {
      final trace = _shotTraces.remove(key)!;
      trace.warning.cancel();
      debugPrint(
        '照片 $key 沒等到回報，鄉民端就離開了（等了 ${trace.clock.elapsed.inSeconds} 秒）',
      );
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
        _traceShotConfirmed(viewerId, id);
        _giveUpTimers.remove('$viewerId#$id')?.cancel();
        // 真的傳過這一張給它才算數，不然任何連著的鄉民端都能讓看板端跳出提示。
        final name = _recorders.shotConfirmed(viewerId, id);
        if (name != null) _notices.add(shotSavedNotice(name));
      case ByeMessage():
        await _viewerGone(viewerId);
      case ResumeMessage():
        await _viewerResumed(viewerId, message);
      case VideoRestartMessage():
        await _restartVideo(viewerId);
      case PingMessage():
        // 已經在收到的當下回覆了（見建構式）。
        break;
      case HelloMessage() ||
          OfferMessage() ||
          CandidatesDoneMessage() ||
          PongMessage() ||
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
      // 鏡頭在註冊時就開了。萬一沒開著（例如被系統收走還沒發現），這裡補開。
      if (!_camera.isOpen) {
        await _openCamera();
        unawaited(_applyFocus(_focus.afterCameraOpened()));
      }
      final link = await _createLink();
      _links[viewerId] = link;
      _recorders.joined(viewerId, join.name);
      if (join.session.isNotEmpty) _sessions[join.session] = viewerId;
      _session.viewerJoined(viewerId);
      notifyListeners();
      await _offer(viewerId, link);
    } catch (e) {
      debugPrint('鄉民端 $viewerId 加入失敗：$e');
      // 鏡頭開不了或連線建不起來：只結束這一個鄉民端，其他人不受影響。
      await _server.dismiss(viewerId, ByeReason.boardStopped);
      await _viewerGone(viewerId);
    }
  }

  /// 把一條剛建好的視訊連線接上訊息的收送，並把連線資訊送給鄉民端。
  Future<void> _offer(String viewerId, ViewerLink link) async {
    link.onCandidate = (candidate) {
      if (identical(_links[viewerId], link)) _server.send(viewerId, candidate);
    };
    link.onCandidatesDone = () {
      if (identical(_links[viewerId], link)) {
        _server.send(viewerId, const CandidatesDoneMessage());
      }
    };
    link.onLost = () => _serial(() => _linkLost(viewerId, link));
    _server.send(viewerId, OfferMessage(sdp: await link.createOffer()));
    _answerTimers.remove(viewerId)?.cancel();
    _answerTimers[viewerId] = Timer(
      _answerTimeout,
      () => _serial(() => _viewerLost(viewerId, link)),
    );
  }

  /// 鄉民端說畫面停住了：把它的視訊連線整條換掉。鏡頭、抄錄的狀態、
  /// 等確認的照片都不動，它仍然是同一位鄉民端。
  Future<void> _restartVideo(String viewerId) async {
    final old = _links[viewerId];
    if (old == null) return;
    debugPrint('鄉民端 $viewerId 要求重建視訊連線');
    try {
      if (!_camera.isOpen) await _openCamera();
      final link = await _createLink();
      // 先換上新的再關舊的：舊的關掉時會回報「斷了」，那時它已經不是現役的那一條。
      _links[viewerId] = link;
      await old.close();
      await _offer(viewerId, link);
    } catch (e) {
      debugPrint('鄉民端 $viewerId 的視訊連線重建失敗：$e');
      await _server.dismiss(viewerId, ByeReason.boardStopped);
      await _viewerGone(viewerId);
    }
  }

  /// 鄉民端在一條新的連線（目前叫 [socketId]）上說：我是那一次觀看，接回來。
  Future<void> _viewerResumed(String socketId, ResumeMessage resume) async {
    if (!resume.isCompatible) {
      await _server.dismiss(socketId, ByeReason.versionMismatch);
      return;
    }
    final viewerId = _sessions[resume.session];
    if (viewerId == null || !_links.containsKey(viewerId)) {
      // 不認得：它已經被當成離開了，或看板端重新註冊過。請它從頭來。
      debugPrint('連線 $socketId 要接回一次不認得的觀看');
      await _server.dismiss(socketId, ByeReason.boardStopped);
      return;
    }
    if (socketId == viewerId) return;
    debugPrint('鄉民端 $viewerId 換了一條新的連線接回來');
    _graceTimers.remove(viewerId)?.cancel();
    _server.adopt(viewerId: viewerId, from: socketId);
    // 「你給我拿啊」：還沒確認的照片再給一次。
    for (final shot in _recorders.resend(viewerId)) {
      debugPrint('照片 ${shot.id} 補送給 $viewerId（第 ${shot.resends} 次）');
      _sendShot(viewerId, shot.id, shot.frame!);
    }
  }

  Future<void> _openCamera() async {
    final opening = _camera.open();
    try {
      await opening.timeout(_cameraOpenTimeout);
    } on TimeoutException {
      // 不等了，但鏡頭之後可能還是開起來：到時已經不在註冊中就關掉，
      // 不能讓它一直開著。
      unawaited(
        opening.then(
          (_) => _serial(() async {
            if (state == BoardState.unregistered) await _closeCamera();
          }),
          onError: (_) {},
        ),
      );
      rethrow;
    }
  }

  /// 一條視訊連線自己斷了。
  ///
  /// 會自己救的鄉民端（加入時帶了代號）不在這裡結束它：它那邊發現畫面停住
  /// 會要求重建；真的走了的話，它的訊息連線斷掉、過了接回的期限就會被當成離開。
  /// 不會自己救的（舊版）才照原本的做法直接結束。
  Future<void> _linkLost(String viewerId, ViewerLink link) async {
    if (!identical(_links[viewerId], link)) return;
    if (_sessions.containsValue(viewerId)) {
      debugPrint('鄉民端 $viewerId 的視訊連線斷了，等它要求重建');
      return;
    }
    await _viewerLost(viewerId, link);
  }

  /// 鄉民端的訊息連線斷了。會自己救的鄉民端先留著一段時間等它接回來，
  /// 期限內沒回來才當成離開。
  Future<void> _viewerDropped(String viewerId) async {
    if (!_links.containsKey(viewerId) ||
        !_sessions.containsValue(viewerId) ||
        _resumeGrace == Duration.zero) {
      await _viewerGone(viewerId);
      return;
    }
    _graceTimers.remove(viewerId)?.cancel();
    _graceTimers[viewerId] = Timer(
      _resumeGrace,
      () => _serial(() async {
        debugPrint('鄉民端 $viewerId 沒有接回來，當成離開');
        await _viewerGone(viewerId);
      }),
    );
  }

  /// 一個鄉民端的畫面連線斷了，或它加入之後一直沒有回覆：告訴它結束了
  /// （它那邊可能還以為在看），再照一般的離開處理。
  Future<void> _viewerLost(String viewerId, ViewerLink link) async {
    // 排隊等到現在，這個鄉民端可能已經離開，甚至換了一條新的連線。
    if (!identical(_links[viewerId], link)) return;
    await _server.dismiss(viewerId, ByeReason.boardStopped);
    await _viewerGone(viewerId);
  }

  /// 一個鄉民端離開了。最後一個離開時回到等候中；鏡頭不關，註冊期間一直開著。
  Future<void> _viewerGone(String viewerId) async {
    _answerTimers.remove(viewerId)?.cancel();
    _graceTimers.remove(viewerId)?.cancel();
    _cancelGiveUps(viewerId);
    _sessions.removeWhere((_, id) => id == viewerId);
    _dropShotTraces(viewerId);
    final link = _links.remove(viewerId);
    _recorders.left(viewerId);
    _session.viewerLeft(viewerId);
    await link?.close();
    notifyListeners();
  }

  Future<void> _endAllViewers(ByeReason reason) async {
    for (final viewerId in _session.stopShowing()) {
      await _server.dismiss(viewerId, reason);
    }
    final links = _links.values.toList();
    _links.clear();
    _recorders.clear();
    _sessions.clear();
    _cancelGiveUps();
    _dropShotTraces();
    for (final timer in [..._answerTimers.values, ..._graceTimers.values]) {
      timer.cancel();
    }
    _answerTimers.clear();
    _graceTimers.clear();
    for (final link in links) {
      await link.close();
    }
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
      _closeCamera,
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
    for (final timer in [
      ..._answerTimers.values,
      ..._graceTimers.values,
      ..._giveUpTimers.values,
    ]) {
      timer.cancel();
    }
    for (final trace in _shotTraces.values) {
      trace.warning.cancel();
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
