import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera_source.dart';

/// 看板端對「一個」鄉民端的視訊連線。每個鄉民端各有一條。
abstract interface class ViewerLink {
  /// 這條連線找到一條可以連到自己的網路路徑時呼叫，要轉送給鄉民端。
  set onCandidate(void Function(CandidateMessage candidate) handler);

  /// 連線中斷時呼叫（鄉民端關掉、網路斷了）。
  set onLost(void Function() handler);

  /// 產生要送給鄉民端的連線資訊。
  Future<String> createOffer();

  /// 收到鄉民端回覆的連線資訊。
  Future<void> acceptAnswer(String sdp);

  /// 收到鄉民端的一條網路路徑。
  Future<void> addCandidate(CandidateMessage candidate);

  Future<void> close();
}

/// 建立一條新的視訊連線。
typedef ViewerLinkFactory = Future<ViewerLink> Function();

/// 用 WebRTC 實作：只送畫面、不送聲音、不接收任何東西。
class WebRtcViewerLink implements ViewerLink {
  WebRtcViewerLink._(this._connection, this._sender);

  /// 畫質上限。區域網路的頻寬遠大於這個數字，設上限是為了不讓手機過熱。
  static const _maxBitrate = 8000000;
  static const _maxFramerate = 30;

  final RTCPeerConnection _connection;
  final RTCRtpSender _sender;
  void Function(CandidateMessage)? _onCandidate;
  void Function()? _onLost;
  bool _closed = false;

  static Future<WebRtcViewerLink> create(WebRtcCameraSource camera) async {
    final stream = camera.stream;
    if (stream == null) throw StateError('鏡頭還沒開，不能建立視訊連線');
    // 兩端都在同一個區域網路，不需要任何外部伺服器協助連線，
    // 所以 iceServers 是空的。這也讓沒有網路的熱點可以用。
    final connection = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    final sender = await connection.addTrack(
      stream.getVideoTracks().first,
      stream,
    );
    final link = WebRtcViewerLink._(connection, sender);
    connection.onIceCandidate = (candidate) {
      final text = candidate.candidate;
      if (text == null || text.isEmpty) return;
      link._onCandidate?.call(
        CandidateMessage(
          candidate: text,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    connection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        link._reportLost();
      }
    };
    return link;
  }

  void _reportLost() {
    if (_closed) return;
    _onLost?.call();
  }

  @override
  set onCandidate(void Function(CandidateMessage) handler) =>
      _onCandidate = handler;

  @override
  set onLost(void Function() handler) => _onLost = handler;

  @override
  Future<String> createOffer() async {
    final offer = await _connection.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await _connection.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    await _connection.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    await _preferResolution();
  }

  /// 網路變差時降低每秒張數，不降解析度。手寫紙的畫面多半是靜止的，
  /// 張數少一點幾乎看不出來，字糊掉就不能用了。
  ///
  /// 要在連線資訊交換完之後才設定，在那之前編碼設定還是空的。
  Future<void> _preferResolution() async {
    final parameters = _sender.parameters;
    parameters.degradationPreference =
        RTCDegradationPreference.MAINTAIN_RESOLUTION;
    for (final encoding in parameters.encodings ?? <RTCRtpEncoding>[]) {
      encoding.maxBitrate = _maxBitrate;
      encoding.maxFramerate = _maxFramerate;
    }
    await _sender.setParameters(parameters);
  }

  @override
  Future<void> addCandidate(CandidateMessage candidate) =>
      _connection.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _connection.close();
  }
}
