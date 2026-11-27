import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';

/// 某個鄉民端送來的一則訊息。
typedef ViewerMessage = ({String viewerId, SignalMessage message});

/// 看板端讓鄉民端連進來、互傳訊息的入口。
abstract interface class SignalServer {
  /// 鄉民端送來的訊息。
  Stream<ViewerMessage> get messages;

  /// 某個鄉民端的連線斷了（它自己關掉，或網路斷了）。
  Stream<String> get disconnections;

  /// 開始接受連線，回傳實際使用的埠。
  Future<int> start({required String boardName});

  /// 送一則訊息給某個鄉民端。它已經斷線時不做任何事。
  void send(String viewerId, SignalMessage message);

  /// 送一筆二進位資料給鄉民端（照片）。要緊接在說明它的那則訊息之後送。
  void sendBytes(String viewerId, Uint8List bytes);

  /// 告訴某個鄉民端結束了，並關掉它的連線。
  Future<void> dismiss(String viewerId, ByeReason reason);

  /// 鄉民端原本那條連線卡住了，它開了一條新的（目前叫 [from]）要接回來：
  /// 之後 [viewerId] 的訊息都走這條新連線。舊的那條直接關掉，
  /// 而且不會從 [disconnections] 通報，因為這位鄉民端並沒有離開。
  void adopt({required String viewerId, required String from});

  /// 停止接受連線，並告訴所有連著的鄉民端看板撤銷註冊了。
  /// 沒有啟動時呼叫也不會出錯。
  Future<void> stop();
}

/// 用 WebSocket 實作。
///
/// 伺服器開在區域網路上，誰都連得到，所以進門前先擋幾種不該出現的連線：
/// 從網頁發出的（瀏覽器會帶 `Origin`，鄉民端不會）、不是從區域網路來的、
/// 以及超過 [maxViewers] 的。連上之後一直不說話的、送來超大訊息的也會被關掉。
class WebSocketSignalServer implements SignalServer {
  WebSocketSignalServer({
    this.preferredPort = defaultBoardPort,
    this.maxViewers = 16,
    this.silenceTimeout = const Duration(seconds: 10),
  });

  /// 一則文字訊息最多多長。最大的是連線資訊，通常幾千個字。
  static const maxMessageLength = 64 * 1024;

  /// 多久確認一次對方還在。對方沒回應時連線會被關掉，看板端才知道它走了。
  static const _pingInterval = Duration(seconds: 10);

  /// 優先使用的埠。被佔用時改由系統挑一個空的。
  final int preferredPort;

  /// 同時最多幾條連線（包含只是來確認看板名稱的）。
  final int maxViewers;

  /// 連上之後這麼久都沒送過一則看得懂的訊息，就關掉。
  final Duration silenceTimeout;

  HttpServer? _server;

  /// 每個鄉民端目前用的那條連線。
  final Map<String, _Peer> _peers = {};
  final _messages = StreamController<ViewerMessage>.broadcast();
  final _disconnections = StreamController<String>.broadcast();
  int _nextId = 1;

  @override
  Stream<ViewerMessage> get messages => _messages.stream;

  @override
  Stream<String> get disconnections => _disconnections.stream;

  @override
  Future<int> start({required String boardName}) async {
    await stop();
    final server = await _bind();
    _server = server;
    server.listen((request) => _accept(server, request, boardName));
    return server.port;
  }

  Future<void> _accept(
    HttpServer server,
    HttpRequest request,
    String boardName,
  ) async {
    try {
      final refusal = _refusal(request);
      if (refusal != null) {
        request.response.statusCode = refusal;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      // 交握的這段時間看板可能已經撤銷註冊了。
      if (!identical(_server, server)) {
        await socket.close();
        return;
      }
      socket.pingInterval = _pingInterval;
      final peer = _Peer(socket, 'viewer-${_nextId++}');
      _peers[peer.id] = peer;
      peer.silence = Timer(silenceTimeout, () => _close(peer));
      socket.add(HelloMessage(name: boardName).encode());
      socket.listen(
        (raw) => _receive(peer, raw),
        onDone: () => _dropped(peer),
        onError: (_) => _dropped(peer),
        cancelOnError: true,
      );
    } catch (_) {
      // 交握到一半對方就斷了之類的：這一條不算，不影響其他連線。
    }
  }

  /// 這個連線要求該不該拒絕。要拒絕時回傳 HTTP 狀態碼，可以收時回傳 null。
  int? _refusal(HttpRequest request) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      return HttpStatus.badRequest;
    }
    // 瀏覽器裡的網頁發出的連線一定帶 Origin，鄉民端不會帶。
    // 不擋的話，使用者開著的任何網頁都能連到區域網路上的看板。
    if (request.headers.value('origin') != null) return HttpStatus.forbidden;
    final remote = request.connectionInfo?.remoteAddress.address;
    if (remote == null || !isLanPeer(remote)) return HttpStatus.forbidden;
    if (_peers.length >= maxViewers) return HttpStatus.serviceUnavailable;
    return null;
  }

  void _receive(_Peer peer, Object? raw) {
    // 這條連線已經被新的那條取代了，之後才到的訊息不算。
    if (!identical(_peers[peer.id], peer)) return;
    // 鄉民端只會送文字訊息，而且都很短。其他的不是正常的鄉民端。
    if (raw is! String || raw.length > maxMessageLength) {
      _close(peer);
      return;
    }
    final SignalMessage message;
    try {
      message = SignalMessage.decode(raw);
    } on FormatException {
      // 看不懂的訊息丟掉就好，不能讓一則壞訊息弄斷整條連線。
      return;
    }
    peer.silence?.cancel();
    _messages.add((viewerId: peer.id, message: message));
  }

  /// 由我們這邊關掉一條不正常的連線，並通報它走了。
  void _close(_Peer peer) {
    _dropped(peer);
    peer.socket.close(WebSocketStatus.policyViolation);
  }

  /// 連線從對方那邊斷掉。我們主動關掉的、或已經被新連線取代的，
  /// 都已經不在 [_peers] 裡，不會再通報。
  void _dropped(_Peer peer) {
    peer.silence?.cancel();
    if (!identical(_peers[peer.id], peer)) return;
    _peers.remove(peer.id);
    _disconnections.add(peer.id);
  }

  @override
  void adopt({required String viewerId, required String from}) {
    final fresh = _peers.remove(from);
    if (fresh == null || from == viewerId) {
      if (fresh != null) _peers[from] = fresh;
      return;
    }
    final stale = _peers[viewerId];
    fresh.id = viewerId;
    _peers[viewerId] = fresh;
    if (stale != null) {
      stale.silence?.cancel();
      // 舊的那條多半已經卡住，正常的關閉流程可能等不到對方回應，這裡不等它。
      unawaited(stale.socket.close().catchError((Object _) {}));
    }
  }

  Future<HttpServer> _bind() async {
    try {
      return await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // 埠被佔用。埠 0 代表請系統挑一個空的，實際的埠會跟著廣播出去。
      return HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
  }

  @override
  void send(String viewerId, SignalMessage message) =>
      _peers[viewerId]?.socket.add(message.encode());

  @override
  void sendBytes(String viewerId, Uint8List bytes) =>
      _peers[viewerId]?.socket.add(bytes);

  @override
  Future<void> dismiss(String viewerId, ByeReason reason) async {
    final peer = _peers.remove(viewerId);
    if (peer == null) return;
    peer.silence?.cancel();
    peer.socket.add(ByeMessage(reason).encode());
    await peer.socket.close();
  }

  @override
  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final viewerId in _peers.keys.toList()) {
      await dismiss(viewerId, ByeReason.boardUnregistered);
    }
    await server?.close(force: true);
  }
}

/// 一條連進來的連線，以及它目前代表哪一位鄉民端。
class _Peer {
  _Peer(this.socket, this.id);

  final WebSocket socket;

  /// 這條連線代表的鄉民端。接回（[SignalServer.adopt]）時會改成原本那位的。
  String id;

  /// 連上之後一直不說話就關掉用的計時。
  Timer? silence;
}
