// lib/pages/sign_detector.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class SignDetectPage extends StatefulWidget {
  const SignDetectPage({super.key});
  @override
  State<SignDetectPage> createState() => _SignDetectPageState();
}

class _SignDetectPageState extends State<SignDetectPage> {
  // ---- config ----
  static const String _modelPath = 'assets/models/best_model.tflite';
  static const String _labelsPath = 'assets/models/labels.txt';

  // You exported with imgsz=640. If you re-export, update this to [1,320,320,3] etc.
  static const List<int> kForcedShape = [1, 640, 640, 3];

  // thresholds
  static const double _iouThr = 0.45;
  static const double _scoreThr = 0.20;

  // ---- runtime ----
  CameraController? _cam;
  Interpreter? _interpreter;

  // labels fallback (overwritten by labels.txt if present)
  List<String> _labels = const ['regulatory', 'stop', 'warning'];

  bool _ready = false;
  String? _error;
  bool _loggedOnce = false;
  int _frameCount = 0; // throttle frames to reduce ImageReader warnings

  // input/output metadata (final after allocateTensors)
  int _inputW = 640, _inputH = 640;
  TensorType _inputType = TensorType.float32;
  TensorType _outputType = TensorType.float32;

  // drawing
  List<_Det> _dets = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _cam?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  // ==================== INIT ====================
  Future<void> _init() async {
    try {
      // Ensure assets exist (fail early with clear message)
      final modelBytes = await _requireAsset(_modelPath);
      final labelsBytes = await _requireAsset(_labelsPath);

      // Camera
      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      _cam = CameraController(
        back,
        ResolutionPreset.medium, // try .low if device struggles
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cam!.initialize();

      // Interpreter
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromBuffer(
        modelBytes.buffer.asUint8List(),
        options: options,
      );

      // *** CRITICAL: force the input shape then allocate (prevents PAD rank error) ***
      _interpreter!.resizeInputTensor(0, kForcedShape);
      _interpreter!.allocateTensors();

      // Cache metadata
      final inT = _interpreter!.getInputTensor(0);
      final outT = _interpreter!.getOutputTensor(0);
      _inputType = inT.type;
      _outputType = outT.type;
      final ishape = inT.shape; // [1,H,W,3]
      _inputH = ishape[1];
      _inputW = ishape[2];

      // Labels
      final labelsStr = String.fromCharCodes(labelsBytes.buffer.asUint8List());
      final ls = labelsStr
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (ls.isNotEmpty) _labels = ls;

      // Start streaming frames
      await _cam!.startImageStream(_onFrame);

      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _ready = false;
        _error = e.toString();
      });
    }
  }

  Future<ByteData> _requireAsset(String assetPath) async {
    try {
      final bd = await rootBundle.load(assetPath);
      if (bd.lengthInBytes == 0) {
        throw FlutterError('Asset is empty: $assetPath');
      }
      return bd;
    } on FlutterError {
      throw FlutterError(
        'Missing asset: $assetPath\n'
        '• Ensure the file exists at that exact path.\n'
        '• In pubspec.yaml add:\n'
        '    flutter:\n'
        '      assets:\n'
        '        - assets/models/\n'
        '• Then run: flutter clean && flutter pub get',
      );
    } catch (e) {
      throw FlutterError('Failed to load $assetPath: $e');
    }
  }

  // ==================== STREAMING / INFERENCE ====================
  bool _isRunning = false;

  void _onFrame(CameraImage imgYUV) async {
    // throttle: process every 2nd frame to reduce ImageReader warnings
    _frameCount = (_frameCount + 1) & 0x7fffffff;
    if ((_frameCount % 2) != 0) return;

    if (_isRunning || _interpreter == null || !mounted) return;
    _isRunning = true;

    try {
      // YUV420 -> RGB
      final rgb = _yuv420toRgb(imgYUV);

      // Resize to model input
      final resized = img.copyResize(
        rgb,
        width: _inputW,
        height: _inputH,
        interpolation: img.Interpolation.linear,
      );

      // Prepare input as nested [1,H,W,3] to match tflite_flutter run()
      final input = _imageToNestedInput(resized);

      // Prepare output buffer using output tensor shape
      final outT = _interpreter!.getOutputTensor(0);
      final oshape = outT.shape;
      final output = _zerosLikeShape(oshape); // nested lists filled with 0.0

      // Run
      _interpreter!.run(input, output);

      if (!_loggedOnce) {
        _loggedOnce = true;
        // ignore: avoid_print
        print('INIT/RUN → input=[1,$_inputH,$_inputW,3] type=$_inputType | out=$oshape type=$_outputType');
        // ignore: avoid_print
        print('labels: $_labels');
      }

      // Reshape/squeeze to rows for parsing (expect [N,6] or [1,N,6] with nms=True)
      List<List<double>> rows;
      if (oshape.length == 2) {
        final n = oshape[0], d = oshape[1];
        rows = List.generate(
          n,
          (i) => List<double>.from((output as List)[i].take(d).map((e) => (e as num).toDouble())),
        );
      } else if (oshape.length == 3 && oshape[0] == 1) {
        final n = oshape[1], d = oshape[2];
        final out0 = (output as List)[0] as List; // [N,6]
        rows = List.generate(
          n,
          (i) => List<double>.from((out0[i] as List).take(d).map((e) => (e as num).toDouble())),
        );
      } else {
        rows = const [];
      }

      // Parse [N,6] (xyxy likely in PIXELS → normalize to 0..1)
      final dets = _parseCaseA(rows);

      // Project normalized (0..1) → preview pixels (camera swaps w/h)
      final pv = _cam!.value.previewSize!;
      final pw = pv.height.toDouble();
      final ph = pv.width.toDouble();
      final projected = dets
          .map((d) => d.copyWith(
                px: d.x * pw,
                py: d.y * ph,
                pw: d.w * pw,
                ph: d.h * ph,
              ))
          .toList();

      // NMS & draw
      setState(() => _dets = _nms(projected, _iouThr));
    } catch (e) {
      // keep streaming even if a frame fails
      // ignore: avoid_print
      print('frame error: $e');
    } finally {
      _isRunning = false;
    }
  }

  // Build [1,H,W,3] as Float32 (0..1) or Uint8 (0..255) depending on model input
  Object _imageToNestedInput(img.Image im) {
    final H = im.height, W = im.width;
    if (_inputType == TensorType.uint8) {
      // [1,H,W,3] of ints
      return [
        List.generate(
          H,
          (y) => List.generate(
            W,
            (x) {
              final p = im.getPixel(x, y);
              return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
            },
            growable: false,
          ),
          growable: false,
        )
      ];
    } else {
      // float32 [0..1]
      return [
        List.generate(
          H,
          (y) => List.generate(
            W,
            (x) {
              final p = im.getPixel(x, y);
              return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
            },
            growable: false,
          ),
          growable: false,
        )
      ];
    }
  }

  /// Create nested zero-filled list matching a shape, for tflite output.
  Object _zerosLikeShape(List<int> shape) {
    Object build(int idx) {
      if (idx == shape.length - 1) {
        return List<double>.filled(shape[idx], 0.0);
      }
      return List.generate(shape[idx], (_) => build(idx + 1), growable: false);
    }
    return build(0);
  }

  // Parse [N,6] rows (Ultralytics TFLite with nms=True)
  // xyxy are typically in PIXELS (0..imgsz), so normalize to 0..1 first.
  List<_Det> _parseCaseA(List<List<double>> rows) {
    final dets = <_Det>[];
    if (rows.isEmpty || rows.first.length < 6) return dets;

    for (final rr in rows) {
      final s = rr[4];
      if (s < _scoreThr) continue;
      final cls = rr[5].round();
      final lbl = (cls >= 0 && cls < _labels.length) ? _labels[cls] : 'id:$cls';

      // pixel → normalized
      double x1 = _pxTo01(rr[0], _inputW.toDouble());
      double y1 = _pxTo01(rr[1], _inputH.toDouble());
      double x2 = _pxTo01(rr[2], _inputW.toDouble());
      double y2 = _pxTo01(rr[3], _inputH.toDouble());

      x1 = x1.clamp(0.0, 1.0);
      y1 = y1.clamp(0.0, 1.0);
      x2 = x2.clamp(0.0, 1.0);
      y2 = y2.clamp(0.0, 1.0);
      if (x2 <= x1 || y2 <= y1) continue;

      dets.add(_Det(
        x: x1,
        y: y1,
        w: x2 - x1,
        h: y2 - y1,
        score: s,
        label: lbl,
      ));
    }
    return dets;
  }

  // If value looks like a pixel (>= ~1.2), divide by size, else assume already 0..1
  double _pxTo01(double v, double size) => v > 1.2 ? v / size : v;

  // YUV420 → RGB
  img.Image _yuv420toRgb(CameraImage image) {
    final w = image.width, h = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel!;

    final out = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      final uvRow = uvRowStride * (y >> 1);
      for (int x = 0; x < w; x++) {
        final yp = y * yPlane.bytesPerRow + x;
        final up = uvRow + (x >> 1) * uvPixelStride;
        final vp = uvRow + (x >> 1) * uvPixelStride;

        final Y = yPlane.bytes[yp] & 0xFF;
        final U = uPlane.bytes[up] & 0xFF;
        final V = vPlane.bytes[vp] & 0xFF;

        final c = Y - 16;
        final d = U - 128;
        final e = V - 128;

        int r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
        int g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
        int b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  // NMS on preview-pixel boxes
  List<_Det> _nms(List<_Det> dets, double iouThresh) {
    final sorted = dets.sorted((a, b) => b.score.compareTo(a.score));
    final keep = <_Det>[];
    while (sorted.isNotEmpty) {
      final best = sorted.removeAt(0);
      keep.add(best);
      sorted.removeWhere((d) => _iou(best, d) > iouThresh);
    }
    return keep;
  }

  double _iou(_Det a, _Det b) {
    final x1 = math.max(a.px, b.px);
    final y1 = math.max(a.py, b.py);
    final x2 = math.min(a.px + a.pw, b.px + b.pw);
    final y2 = math.min(a.py + a.ph, b.py + b.ph);
    final inter = math.max(0, x2 - x1) * math.max(0, y2 - y1);
    final union = a.pw * a.ph + b.pw * b.ph - inter;
    if (union <= 0) return 0;
    return inter / union;
  }

  // ==================== UI ====================
  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Signage Detector')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 60, color: Colors.redAccent),
                const SizedBox(height: 12),
                const Text('Unable to start detector',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _ready = false;
                    });
                    _init();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_ready || _cam == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_cam!),
          CustomPaint(painter: _BoxesPainter(_dets), size: Size.infinite),
        ],
      ),
    );
  }
}

// ==================== models & painter ====================

class _Det {
  final double x, y, w, h; // normalized 0..1
  final double score;
  final String label;
  final double px, py, pw, ph; // in preview pixels
  _Det({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.score,
    required this.label,
    this.px = 0,
    this.py = 0,
    this.pw = 0,
    this.ph = 0,
  });
  _Det copyWith({double? px, double? py, double? pw, double? ph}) => _Det(
        x: x,
        y: y,
        w: w,
        h: h,
        score: score,
        label: label,
        px: px ?? this.px,
        py: py ?? this.py,
        pw: pw ?? this.pw,
        ph: ph ?? this.ph,
      );
}

class _BoxesPainter extends CustomPainter {
  final List<_Det> dets;
  _BoxesPainter(this.dets);

  @override
  void paint(Canvas canvas, Size size) {
    final box = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF00E676);
    final bg = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xAA000000);

    for (final d in dets) {
      final r = Rect.fromLTWH(d.px, d.py, d.pw, d.ph);
      canvas.drawRect(r, box);

      final span = TextSpan(
        text: '${d.label} ${(d.score * 100).toStringAsFixed(0)}%',
        style: const TextStyle(color: Colors.white, fontSize: 12),
      );
      final tp = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
      final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(r.left, math.max(0, r.top - tp.height - 6), tp.width + 8, tp.height + 6),
        const Radius.circular(6),
      );
      canvas.drawRRect(rr, bg);
      tp.paint(canvas, Offset(rr.left + 4, rr.top + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _BoxesPainter oldDelegate) => true;
}
