import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../services/inference_worker.dart';

class SignDetectPage extends StatefulWidget {
  const SignDetectPage({super.key});
  @override
  State<SignDetectPage> createState() => _SignDetectPageState();
}

class _SignDetectPageState extends State<SignDetectPage> {
  // ---- config ----
  static const String _modelPath = 'assets/models/best_model.tflite';
  static const String _labelsPath = 'assets/models/labels.txt';
  static const List<int> kForcedShape = [1, 640, 640, 3]; // keep 640 as you requested

  // thresholds
  static const double _iouThr = 0.45;
  static const double _scoreThr = 0.20;

  // ---- runtime ----
  CameraController? _cam;

  // isolate plumbing
  Isolate? _iso;
  SendPort? _workerSend;
  StreamSubscription? _workerSub;
  bool _workerBusy = false;

  // state
  bool _ready = false;
  String? _error;
  int _frameCount = 0; // throttle frames

  // labels fallback (overwritten by labels.txt if present)
  List<String> _labels = const ['regulatory', 'stop', 'warning'];

  // drawing
  List<_Det> _dets = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _workerSub?.cancel();
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _cam?.dispose();
    super.dispose();
  }

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
        ResolutionPreset.medium, // keep medium; lag will be solved by isolate
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cam!.initialize();

      // Labels
      final labelsStr = String.fromCharCodes(labelsBytes.buffer.asUint8List());
      final ls = labelsStr
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (ls.isNotEmpty) _labels = ls;

      // Start worker isolate (single listener)
      await _startWorker(modelBytes.buffer.asUint8List(), _labels);

      // Start camera stream once
      if (!_cam!.value.isStreamingImages) {
        await _cam!.startImageStream(_onFrame);
      }

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
    final bd = await rootBundle.load(assetPath);
    if (bd.lengthInBytes == 0) {
      throw FlutterError('Asset is empty: $assetPath');
    }
    return bd;
  }

  Future<void> _startWorker(Uint8List modelBytes, List<String> labels) async {
    if (_iso != null) return; // prevent double spawn on hot reload

    final port = ReceivePort();
    _iso = await Isolate.spawn(inferenceEntry, port.sendPort);

    _workerSub = port.listen((dynamic m) {
      if (m is! Map) return;
      final t = m['type'];

      if (t == 'ready') {
        _workerSend = m['port'] as SendPort;
        _workerSend!.send({
          'type': 'init',
          'model': modelBytes,
          'labels': labels,
          'forcedShape': kForcedShape,
          'threads': 3, // a little more parallelism
        });
        return;
      }

      if (t == 'log') {
        // print('[worker] ${m['msg']}');
        return;
      }

      if (t == 'error') {
        // print('[worker-error] ${m['msg']}');
        _workerBusy = false;
        return;
      }

      if (t == 'result') {
        final detsNorm = (m['dets'] as List).cast<Map>(); // already NMSed in worker
        if (_cam != null && _cam!.value.isInitialized) {
          final pv = _cam!.value.previewSize!;
          final pw = pv.height.toDouble(); // rotated preview dims
          final ph = pv.width.toDouble();
          final projected = detsNorm.map((dn) {
            final x = (dn['x'] as num).toDouble();
            final y = (dn['y'] as num).toDouble();
            final w = (dn['w'] as num).toDouble();
            final h = (dn['h'] as num).toDouble();
            return _Det(
              x: x,
              y: y,
              w: w,
              h: h,
              score: (dn['score'] as num).toDouble(),
              label: dn['label'] as String,
            ).copyWith(
              px: x * pw,
              py: y * ph,
              pw: w * pw,
              ph: h * ph,
            );
          }).toList();
          setState(() => _dets = projected);
        }
        _workerBusy = false;
      }
    });
  }

  void _onFrame(CameraImage imgYUV) {
    // throttle a bit to keep the pipeline smooth without changing model size
    _frameCount = (_frameCount + 1) & 0x7fffffff;
    if ((_frameCount % 2) != 0) return; // process 1 of every 2 frames

    if (_workerSend == null || _workerBusy || !mounted) return;

    final y = TransferableTypedData.fromList([imgYUV.planes[0].bytes]);
    final u = TransferableTypedData.fromList([imgYUV.planes[1].bytes]);
    final v = TransferableTypedData.fromList([imgYUV.planes[2].bytes]);

    _workerBusy = true;
    _workerSend!.send({
      'type': 'frame',
      'y': y,
      'u': u,
      'v': v,
      'w': imgYUV.width,
      'h': imgYUV.height,
      'yRowStride': imgYUV.planes[0].bytesPerRow,
      'uvRowStride': imgYUV.planes[1].bytesPerRow,
      'uvPixelStride': imgYUV.planes[1].bytesPerPixel!,
      'iou': _iouThr,
      'conf': _scoreThr,
    });
  }

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
                    setState(() { _error = null; _ready = false; });
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
