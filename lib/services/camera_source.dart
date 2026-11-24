import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 看板端的鏡頭。
///
/// 用介面隔開，畫面測試才能換成假的，不需要真的鏡頭。
abstract interface class CameraSource {
  bool get isOpen;

  /// 確認使用者允許使用相機，還沒允許時會跳出系統的詢問。
  /// 被拒絕時丟例外。
  Future<void> ensurePermission();

  /// 開啟鏡頭。已經開著時不做任何事。
  Future<void> open();

  /// 關閉鏡頭。沒開時不做任何事。
  Future<void> close();

  Future<void> switchCamera();

  Future<void> setZoom(double zoom);

  /// 對畫面上的一點對焦。[x]、[y] 是 0 到 1 的比例，(0, 0) 是左上角。
  Future<void> focusAt(double x, double y);

  /// 看板端自己看的預覽畫面。
  Widget buildPreview();
}

/// 用 WebRTC 的鏡頭擷取實作。同一個鏡頭畫面會分給所有正在看的鄉民端。
class WebRtcCameraSource implements CameraSource {
  MediaStream? _stream;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _rendererReady = false;

  /// 目前的鏡頭畫面，給視訊連線使用。沒開鏡頭時是 null。
  MediaStream? get stream => _stream;

  MediaStreamTrack? get _track {
    final tracks = _stream?.getVideoTracks();
    return tracks == null || tracks.isEmpty ? null : tracks.first;
  }

  @override
  bool get isOpen => _stream != null;

  @override
  Future<void> ensurePermission() async {
    if (isOpen) return;
    // 套件沒有單獨詢問權限的方法，開一次鏡頭就會觸發系統的詢問。
    await open();
    await close();
  }

  @override
  Future<void> open() async {
    if (isOpen) return;
    if (!_rendererReady) {
      await _renderer.initialize();
      _rendererReady = true;
    }
    // 拍手寫紙要看得清楚字，所以要求後鏡頭和 1080p。不要聲音。
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'environment',
        'width': 1920,
        'height': 1080,
        'frameRate': 30,
      },
    });
    _stream = stream;
    _renderer.srcObject = stream;
  }

  @override
  Future<void> close() async {
    final stream = _stream;
    if (stream == null) return;
    _stream = null;
    _renderer.srcObject = null;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  @override
  Future<void> switchCamera() async {
    final track = _track;
    if (track != null) await Helper.switchCamera(track);
  }

  @override
  Future<void> setZoom(double zoom) async {
    final track = _track;
    if (track != null) await Helper.setZoom(track, zoom);
  }

  @override
  Future<void> focusAt(double x, double y) async {
    final track = _track;
    if (track == null) return;
    await Helper.setFocusMode(track, CameraFocusMode.auto);
    await Helper.setFocusPoint(track, Point(x, y));
  }

  @override
  Widget buildPreview() => RTCVideoView(
    _renderer,
    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  );
}
