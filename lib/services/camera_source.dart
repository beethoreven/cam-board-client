import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 鏡頭套用一組設定之後回報的結果。
class CameraOutcome {
  const CameraOutcome({this.lockedDistance, this.distanceSupported = true});

  /// 對焦鎖住的距離。鏡頭沒回報，或現在是自動對焦時是 null。
  final double? lockedDistance;

  /// 要求「直接設成某個對焦距離」時，這支手機支不支援。
  /// 不支援時鏡頭會停在目前的位置。
  final bool distanceSupported;
}

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

  /// 套用整組鏡頭設定：縮放倍率和對焦方式。
  ///
  /// 兩項一定要一起給。鏡頭的設定是整組換掉的，分開設定會互相蓋掉
  /// （之前「點擊對焦後縮放掉回 1 倍」就是這個原因）。
  Future<CameraOutcome> apply({
    required double zoom,
    required FocusCommand focus,
  });

  /// 擷取鏡頭現在的畫面，原樣回傳：還沒經過視訊壓縮，也還沒轉正或壓成圖檔。
  Future<RawFrame> captureFrame();

  /// 看板端自己看的預覽畫面。
  Widget buildPreview();

  /// 預覽畫面的寬除以高（已經把手機的方向算進去）。還沒有畫面時是 null。
  /// 用來把點在預覽框上的位置換算成畫面上的位置。
  double? get previewAspectRatio;
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

  /// 縮放、對焦、擷取走我們自己寫的 Android 鏡頭控制
  /// （android/.../CameraControl.kt），不用 flutter_webrtc 的 Helper。原因見那個檔案開頭。
  static const _channel = MethodChannel(
    'tw.com.tutorarthur.camboard.client/camera',
  );

  @override
  Future<CameraOutcome> apply({
    required double zoom,
    required FocusCommand focus,
  }) async {
    final track = _track;
    if (track == null) return const CameraOutcome();
    final reply = await _channel.invokeMapMethod<String, Object?>('apply', {
      'trackId': track.id,
      'zoom': zoom,
      ...switch (focus) {
        ContinuousFocus() => {'focus': 'continuous'},
        HoldFocus() => {'focus': 'hold'},
        PointFocus(:final x, :final y) => {'focus': 'point', 'x': x, 'y': y},
        DistanceFocus(:final distance) => {
          'focus': 'distance',
          'distance': distance,
        },
      },
    });
    return CameraOutcome(
      lockedDistance: (reply?['distance'] as num?)?.toDouble(),
      distanceSupported: reply?['supported'] as bool? ?? true,
    );
  }

  @override
  Future<RawFrame> captureFrame() async {
    final track = _track;
    if (track == null) throw StateError('鏡頭還沒開，不能拍照');
    final reply = await _channel.invokeMapMethod<String, Object?>(
      'captureFrame',
      {'trackId': track.id},
    );
    if (reply == null) throw StateError('鏡頭沒有回傳畫面');
    return RawFrame(
      width: reply['width']! as int,
      height: reply['height']! as int,
      rotation: reply['rotation']! as int,
      i420: reply['bytes']! as Uint8List,
    );
  }

  @override
  double? get previewAspectRatio {
    final value = _renderer.value;
    if (value.width <= 0 || value.height <= 0) return null;
    final sideways = value.rotation == 90 || value.rotation == 270;
    return sideways ? value.height / value.width : value.width / value.height;
  }

  @override
  Widget buildPreview() => RTCVideoView(
    _renderer,
    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  );
}
