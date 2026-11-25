package tw.com.tutorarthur.camboard.client

import android.app.Activity
import android.graphics.Rect
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.MeteringRectangle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.webrtc.Camera2Capturer
import org.webrtc.CameraEnumerationAndroid
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 看板端自己的鏡頭控制：縮放、對焦、擷取一張畫面。
 *
 * 為什麼不用 flutter_webrtc 提供的：它在 Android 上設定縮放或對焦點時，都是把鏡頭的
 * 設定整個換掉，而且各自只帶自己那一項，所以設定對焦會讓縮放掉回 1 倍；它也沒有真的
 * 觸發對焦。它的擷取功能存的是 JPEG，不是沒有壓縮的圖。這裡把縮放和對焦放在同一次
 * 設定裡，並且自己把鏡頭的畫面原樣交出去（轉成 PNG 由鄉民端做）。
 *
 * 這段程式要用到 flutter_webrtc 和 WebRTC 沒有公開的欄位（用反射取得），是照
 * flutter_webrtc 1.6.3（WebRTC SDK 150.7871.04）寫的。套件升版後如果欄位改了名字，
 * 這裡會回報明確的錯誤，不會讓 app 當掉；到時要對照新版原始碼修改 [session]。
 */
class CameraControl(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "tw.com.tutorarthur.camboard.client/camera"
        private const val TAG = "CamBoardCamera"

        /** 等對焦完成最多等多久。 */
        private const val FOCUS_TIMEOUT_MS = 3000L

        /** 等下一張畫面最多等多久。 */
        private const val FRAME_TIMEOUT_MS = 3000L

        /** 對焦區域的邊長，佔畫面寬度的比例。 */
        private const val FOCUS_AREA = 0.12
    }

    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "apply" -> apply(call, result)
                "captureFrame" -> captureFrame(call, result)
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "${call.method} 失敗", e)
            result.error("camera_control", e.message ?: e.toString(), null)
        }
    }

    /** WebRTC 目前這一次開啟鏡頭所用到的東西。 */
    private class Session(
        val manager: CameraManager,
        val captureSession: CameraCaptureSession,
        val device: CameraDevice,
        val format: CameraEnumerationAndroid.CaptureFormat,
        val fpsUnitFactor: Int,
        val surface: Surface,
        val handler: Handler,
    )

    private fun session(trackId: String): Session {
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: error("視訊套件還沒啟動")
        val callHandler = read(plugin, plugin.javaClass, "methodCallHandler")
        val userMedia = read(callHandler, callHandler.javaClass, "getUserMediaImpl")
        val info = userMedia.javaClass.getMethod("getCapturerInfo", String::class.java)
            .invoke(userMedia, trackId) ?: error("找不到這個鏡頭畫面")
        val capturer = info.javaClass.getField("capturer").get(info)
        if (capturer !is Camera2Capturer) error("這支手機用的是舊的相機介面，不支援這些鏡頭控制")
        val base = Camera2Capturer::class.java.superclass!!
        val current = readOrNull(capturer, base, "currentSession") ?: error("鏡頭還沒開好")
        val type = current.javaClass
        return Session(
            manager = read(capturer, Camera2Capturer::class.java, "cameraManager") as CameraManager,
            captureSession = read(current, type, "captureSession") as CameraCaptureSession,
            device = read(current, type, "cameraDevice") as CameraDevice,
            format = read(current, type, "captureFormat") as CameraEnumerationAndroid.CaptureFormat,
            fpsUnitFactor = read(current, type, "fpsUnitFactor") as Int,
            surface = read(current, type, "surface") as Surface,
            handler = read(current, type, "cameraThreadHandler") as Handler,
        )
    }

    private fun read(target: Any, type: Class<*>, name: String): Any =
        readOrNull(target, type, name) ?: error("鏡頭還沒開好（$name 是空的）")

    private fun readOrNull(target: Any, type: Class<*>, name: String): Any? {
        val field = try {
            type.getDeclaredField(name)
        } catch (e: NoSuchFieldException) {
            error("視訊套件的內部結構變了：${type.simpleName} 裡找不到 $name。這段程式是照 flutter_webrtc 1.6.3 寫的")
        }
        field.isAccessible = true
        return field.get(target)
    }

    /**
     * 套用整組鏡頭設定。每次都帶完整的設定，鏡頭的設定才不會互相蓋掉。
     *
     * 參數：trackId、zoom（倍率）、focus：
     * - "continuous"：持續自動對焦。
     * - "hold"：停在目前的對焦位置，不再自己重新對焦。
     * - "point"：對 (x, y) 對焦一次，然後停在那裡。x、y 是預覽畫面上 0 到 1 的比例。
     * - "distance"：直接把對焦設在 distance（上一次 "point" 或 "hold" 回傳的值）。
     *
     * 回傳：zoom（實際套用的倍率）、distance（鎖住的對焦距離，讀不到時沒有這一項）、
     * focused（"point" 時相機回報有沒有對到）、supported（"distance" 時手機支不支援）。
     */
    private fun apply(call: MethodCall, result: MethodChannel.Result) {
        val s = session(call.argument<String>("trackId")!!)
        val focus = call.argument<String>("focus") ?: "continuous"
        val chars = s.manager.getCameraCharacteristics(s.device.id)
        val active = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            ?: error("讀不到感光元件的大小")
        val maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f).toDouble()
        val zoom = (call.argument<Double>("zoom") ?: 1.0).coerceIn(1.0, maxOf(1.0, maxZoom))

        val cropWidth = (active.width() / zoom).toInt()
        val cropHeight = (active.height() / zoom).toInt()
        val cropLeft = (active.width() - cropWidth) / 2
        val cropTop = (active.height() - cropHeight) / 2
        val crop = Rect(cropLeft, cropTop, cropLeft + cropWidth, cropTop + cropHeight)

        fun request(): CaptureRequest.Builder =
            s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                set(CaptureRequest.SCALER_CROP_REGION, crop)
                set(
                    CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                    Range(s.format.framerate.min / s.fpsUnitFactor, s.format.framerate.max / s.fpsUnitFactor),
                )
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.CONTROL_AE_LOCK, false)
                addTarget(s.surface)
            }

        val reply = Reply(result, zoom)
        Log.i(TAG, "apply zoom=$zoom focus=$focus crop=$crop")

        when (focus) {
            "continuous" -> {
                val builder = request()
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                s.captureSession.setRepeatingRequest(builder.build(), LensWatch("continuous").callback, s.handler)
                reply.send()
            }

            "hold" -> {
                // 自動對焦模式設成「要我說了才對焦」，而且不說，鏡頭就停在目前的位置。
                val builder = request()
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                var seen = 0
                val lens = LensWatch("hold")
                s.captureSession.setRepeatingRequest(
                    builder.build(),
                    object : CameraCaptureSession.CaptureCallback() {
                        override fun onCaptureCompleted(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            total: TotalCaptureResult,
                        ) {
                            lens.see(total)
                            // 前幾張可能還是切換前的設定，多等幾張再讀對焦距離。
                            if (++seen < 5) return
                            reply.distance = total.get(CaptureResult.LENS_FOCUS_DISTANCE)
                            reply.send()
                        }
                    },
                    s.handler,
                )
                main.postDelayed({ reply.send() }, FOCUS_TIMEOUT_MS)
            }

            "point" -> {
                val area = focusArea(
                    chars, s, crop, active,
                    call.argument<Double>("x") ?: 0.5,
                    call.argument<Double>("y") ?: 0.5,
                )
                val builder = request()
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(area))

                var triggered = false
                var scanning = false
                var sinceTrigger = 0
                val lens = LensWatch("point")
                val watch = object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        total: TotalCaptureResult,
                    ) {
                        lens.see(total)
                        if (request.get(CaptureRequest.CONTROL_AF_TRIGGER) == CameraMetadata.CONTROL_AF_TRIGGER_START) {
                            triggered = true
                        }
                        if (!triggered) return
                        sinceTrigger++
                        val state = total.get(CaptureResult.CONTROL_AF_STATE)
                        if (state == CameraMetadata.CONTROL_AF_STATE_ACTIVE_SCAN) scanning = true
                        val locked = state == CameraMetadata.CONTROL_AF_STATE_FOCUSED_LOCKED ||
                            state == CameraMetadata.CONTROL_AF_STATE_NOT_FOCUSED_LOCKED
                        // 剛觸發的那幾張可能還帶著上一次鎖住的狀態，
                        // 要先看到「正在對焦」，或多等幾張，才算數。
                        if (locked && (scanning || sinceTrigger > 8)) {
                            reply.focused = state == CameraMetadata.CONTROL_AF_STATE_FOCUSED_LOCKED
                            reply.distance = total.get(CaptureResult.LENS_FOCUS_DISTANCE)
                            reply.send()
                        }
                    }
                }
                s.captureSession.setRepeatingRequest(builder.build(), watch, s.handler)
                builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
                s.captureSession.capture(builder.build(), watch, s.handler)
                main.postDelayed({ reply.send() }, FOCUS_TIMEOUT_MS)
            }

            "distance" -> {
                val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
                val nearest = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
                val manual = capabilities.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
                val distance = call.argument<Double>("distance")
                if (!manual || nearest <= 0f || distance == null) {
                    reply.supported = false
                    reply.send()
                    return
                }
                val builder = request()
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                builder.set(CaptureRequest.LENS_FOCUS_DISTANCE, distance.toFloat().coerceIn(0f, nearest))
                s.captureSession.setRepeatingRequest(builder.build(), LensWatch("distance").callback, s.handler)
                reply.distance = distance.toFloat()
                reply.send()
            }

            else -> error("不認得的對焦方式：$focus")
        }
    }

    /**
     * 記下鏡頭實際在做什麼：對焦狀態一變、或鏡頭位置移動超過一點點，就寫一筆紀錄。
     * 用來從紀錄判斷「關掉自動對焦之後鏡頭有沒有自己動」，不影響行為。
     */
    private inner class LensWatch(private val mode: String) {
        private var lastState: Int? = null
        private var lastDistance: Float? = null

        fun see(total: TotalCaptureResult) {
            val state = total.get(CaptureResult.CONTROL_AF_STATE)
            val distance = total.get(CaptureResult.LENS_FOCUS_DISTANCE)
            val before = lastDistance
            val moved = distance != null && (before == null || Math.abs(distance - before) > 0.05f)
            if (state == lastState && !moved) return
            Log.i(
                TAG,
                "lens mode=$mode afMode=${total.get(CaptureResult.CONTROL_AF_MODE)} " +
                    "afState=$state distance=$distance lensState=${total.get(CaptureResult.LENS_STATE)}",
            )
            lastState = state
            if (moved) lastDistance = distance
        }

        /** 只觀察、不做別的事的回呼。 */
        val callback = object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                total: TotalCaptureResult,
            ) = see(total)
        }
    }

    /** 回覆 Dart 那一端，而且只回覆一次（對焦完成和逾時可能都會想回覆）。 */
    private inner class Reply(private val result: MethodChannel.Result, private val zoom: Double) {
        private val sent = AtomicBoolean(false)
        @Volatile var distance: Float? = null
        @Volatile var focused: Boolean? = null
        @Volatile var supported: Boolean = true

        fun send() {
            if (!sent.compareAndSet(false, true)) return
            Log.i(TAG, "reply zoom=$zoom distance=$distance focused=$focused supported=$supported")
            main.post {
                result.success(
                    mapOf(
                        "zoom" to zoom,
                        "distance" to distance?.toDouble(),
                        "focused" to focused,
                        "supported" to supported,
                    ),
                )
            }
        }
    }

    /**
     * 把預覽畫面上的一點換算成感光元件上的對焦區域。
     *
     * 預覽畫面是轉正之後的樣子，感光元件的方向通常跟手機差 90 度；
     * 送出去的畫面（16:9）又只是感光元件（通常 4:3）中間的一部分。
     */
    private fun focusArea(
        chars: CameraCharacteristics,
        s: Session,
        crop: Rect,
        active: Rect,
        u: Double,
        v: Double,
    ): MeteringRectangle {
        @Suppress("DEPRECATION")
        val deviceDegrees = when (activity.windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val sensorDegrees = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val front = chars.get(CameraCharacteristics.LENS_FACING) == CameraMetadata.LENS_FACING_FRONT
        // 跟 WebRTC 算「這張畫面要轉幾度才是正的」用同一個算法。
        val rotation = (sensorDegrees + if (front) deviceDegrees else 360 - deviceDegrees) % 360
        val (bx, by) = when (rotation) {
            90 -> Pair(v, 1 - u)
            180 -> Pair(1 - u, 1 - v)
            270 -> Pair(1 - v, u)
            else -> Pair(u, v)
        }

        val outAspect = s.format.width.toDouble() / s.format.height
        val cropAspect = crop.width().toDouble() / crop.height()
        val visibleWidth: Double
        val visibleHeight: Double
        if (outAspect > cropAspect) {
            visibleWidth = crop.width().toDouble()
            visibleHeight = visibleWidth / outAspect
        } else {
            visibleHeight = crop.height().toDouble()
            visibleWidth = visibleHeight * outAspect
        }
        val centerX = crop.left + (crop.width() - visibleWidth) / 2 + bx * visibleWidth
        val centerY = crop.top + (crop.height() - visibleHeight) / 2 + by * visibleHeight
        val side = (visibleWidth * FOCUS_AREA).toInt().coerceAtLeast(1)
        val left = (centerX - side / 2).toInt().coerceIn(0, maxOf(0, active.width() - side))
        val top = (centerY - side / 2).toInt().coerceIn(0, maxOf(0, active.height() - side))
        return MeteringRectangle(left, top, side, side, MeteringRectangle.METERING_WEIGHT_MAX)
    }

    /**
     * 擷取鏡頭的下一張畫面，原樣交出去：不換色彩格式、不轉正、不壓縮。
     *
     * 這些事之前都在手機上做，一張要 1.2～1.7 秒；現在交給鄉民端的電腦做。
     * 回傳寬、高、要順時針轉幾度才是正的，以及畫面的內容（格式見 [pack]）。
     */
    private fun captureFrame(call: MethodCall, result: MethodChannel.Result) {
        val trackId = call.argument<String>("trackId")!!
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: error("視訊套件還沒啟動")
        val track = plugin.getLocalTrack(trackId)?.track as? VideoTrack ?: error("找不到這個鏡頭畫面")
        val done = AtomicBoolean(false)
        val taken = AtomicBoolean(false)

        fun finish(action: () -> Unit) {
            if (done.compareAndSet(false, true)) main.post(action)
        }

        lateinit var sink: VideoSink
        sink = VideoSink { frame ->
            if (!taken.compareAndSet(false, true)) return@VideoSink
            main.post { track.removeSink(sink) }
            try {
                val started = System.currentTimeMillis()
                val reply = pack(frame)
                Log.i(
                    TAG,
                    "capture ${reply["width"]}x${reply["height"]} rotation=${reply["rotation"]} " +
                        "raw=${(reply["bytes"] as ByteArray).size} bytes in ${System.currentTimeMillis() - started} ms",
                )
                finish { result.success(reply) }
            } catch (e: Throwable) {
                Log.e(TAG, "擷取畫面失敗", e)
                finish { result.error("camera_control", e.message ?: e.toString(), null) }
            }
        }
        track.addSink(sink)
        main.postDelayed({
            if (!taken.get()) {
                track.removeSink(sink)
                finish { result.error("camera_control", "鏡頭沒有送出畫面", null) }
            }
        }, FRAME_TIMEOUT_MS)
    }

    /**
     * 把一張畫面複製成一整塊：亮度、色差 U、色差 V 依序接在一起（I420），
     * 每一列之間沒有多餘的空位，所以大小固定是寬×高×1.5。
     * 複製出來之後就不依賴 WebRTC 的畫面了。
     */
    private fun pack(frame: VideoFrame): Map<String, Any> {
        val i420 = frame.buffer.toI420() ?: error("讀不到畫面的內容")
        try {
            val width = i420.width
            val height = i420.height
            if (width % 2 != 0 || height % 2 != 0) error("畫面的寬高不是偶數：${width}x$height")
            val bytes = ByteArray(width * height * 3 / 2)
            var at = copyPlane(i420.dataY, i420.strideY, width, height, bytes, 0)
            at = copyPlane(i420.dataU, i420.strideU, width / 2, height / 2, bytes, at)
            copyPlane(i420.dataV, i420.strideV, width / 2, height / 2, bytes, at)
            return mapOf(
                "width" to width,
                "height" to height,
                "rotation" to frame.rotation,
                "bytes" to bytes,
            )
        } finally {
            i420.release()
        }
    }

    /** 一列一列複製，跳過每一列後面可能多出來的空位。回傳下一塊要從哪裡開始寫。 */
    private fun copyPlane(
        source: ByteBuffer,
        stride: Int,
        width: Int,
        height: Int,
        into: ByteArray,
        start: Int,
    ): Int {
        val plane = source.duplicate()
        var at = start
        for (row in 0 until height) {
            plane.position(row * stride)
            plane.get(into, at, width)
            at += width
        }
        return at
    }
}
