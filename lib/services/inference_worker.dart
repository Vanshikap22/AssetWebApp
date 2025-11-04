import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

@pragma('vm:entry-point')
void inferenceEntry(SendPort mainSendPort) async {
  final inbox = ReceivePort();
  mainSendPort.send({'type': 'ready', 'port': inbox.sendPort});

  late Interpreter _interpreter;
  late TensorType _inType;
  late int _inW, _inH;
  List<String> _labels = const [];
  double _iouThr = 0.45;
  double _confThr = 0.20;

  double _iou(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ax1 = a['x'] as double;
    final ay1 = a['y'] as double;
    final ax2 = ax1 + (a['w'] as double);
    final ay2 = ay1 + (a['h'] as double);
    final bx1 = b['x'] as double;
    final by1 = b['y'] as double;
    final bx2 = bx1 + (b['w'] as double);
    final by2 = by1 + (b['h'] as double);
    final x1 = math.max(ax1, bx1);
    final y1 = math.max(ay1, by1);
    final x2 = math.min(ax2, bx2);
    final y2 = math.min(ay2, by2);
    final inter = math.max(0, x2 - x1) * math.max(0, y2 - y1);
    final ua = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter;
    return ua <= 0 ? 0.0 : inter / ua;
  }

  List<Map<String, dynamic>> _parseRowsAndNms(List<List<double>> rows, double iouThr) {
    final dets = <Map<String, dynamic>>[];
    for (final rr in rows) {
      if (rr.length < 6) continue;
      final score = rr[4];
      if (score < _confThr) continue;
      final cls = rr[5].round();
      final lbl = (cls >= 0 && cls < _labels.length) ? _labels[cls] : 'id:$cls';
      double x1 = rr[0], y1 = rr[1], x2 = rr[2], y2 = rr[3];
      double norm(double v, num size) => v > 1.2 ? v / size.toDouble() : v; 
      x1 = norm(x1, _inW).clamp(0.0, 1.0);
      y1 = norm(y1, _inH).clamp(0.0, 1.0);
      x2 = norm(x2, _inW).clamp(0.0, 1.0);
      y2 = norm(y2, _inH).clamp(0.0, 1.0);
      if (x2 <= x1 || y2 <= y1) continue;
      dets.add({'x': x1, 'y': y1, 'w': x2 - x1, 'h': y2 - y1, 'score': score, 'label': lbl});
    }

    // NMS in worker to reduce payload back to UI
    dets.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
    final keep = <Map<String, dynamic>>[];
    while (dets.isNotEmpty) {
      final best = dets.removeAt(0);
      keep.add(best);
      dets.removeWhere((d) => _iou(best, d) > iouThr);
    }
    return keep;
  }

  Future<void> _handleInit(Map msg) async {
    try {
      final model = msg['model'] as Uint8List;
      final labels = (msg['labels'] as List).cast<String>();
      final forced = (msg['forcedShape'] as List).cast<int>();
      final threads = (msg['threads'] as int?) ?? 3;

      final opt = InterpreterOptions()..threads = threads;
      _interpreter = await Interpreter.fromBuffer(model, options: opt);
      _interpreter.resizeInputTensor(0, forced);
      _interpreter.allocateTensors();

      final inT = _interpreter.getInputTensor(0);
      _inType = inT.type;
      _inH = inT.shape[1];
      _inW = inT.shape[2];
      _labels = labels;

      mainSendPort.send({'type': 'log', 'msg': 'Worker init OK → [1,$_inH,$_inW,3] $_inType'});
    } catch (e) {
      mainSendPort.send({'type': 'error', 'msg': 'Init failed: $e'});
    }
  }

  img.Image _yuv420ToRgb({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int w,
    required int h,
    required int yRowStride,
    required int uvRowStride,
    required int uvPixelStride,
  }) {
    final out = img.Image(width: w, height: h);
    for (int yi = 0; yi < h; yi++) {
      final uvRow = uvRowStride * (yi >> 1);
      final yRow = yRowStride * yi;
      for (int xi = 0; xi < w; xi++) {
        final yIndex = yRow + xi;
        final uvIndex = uvRow + (xi >> 1) * uvPixelStride;
        final Y = y[yIndex] & 0xFF;
        final U = u[uvIndex] & 0xFF;
        final V = v[uvIndex] & 0xFF;
        final c = Y - 16;
        final d = U - 128;
        final e = V - 128;
        int r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
        int g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
        int b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);
        out.setPixelRgb(xi, yi, r, g, b);
      }
    }
    return out;
  }

  Object _imageToInput(img.Image im, TensorType type) {
    final H = im.height, W = im.width;
    if (type == TensorType.uint8) {
      return [
        List.generate(H, (y) => List.generate(W, (x) {
              final p = im.getPixel(x, y);
              return [p.r.toInt(), p.g.toInt(), p.b.toInt()];
            }, growable: false),
            growable: false)
      ];
    } else {
      return [
        List.generate(H, (y) => List.generate(W, (x) {
              final p = im.getPixel(x, y);
              return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
            }, growable: false),
            growable: false)
      ];
    }
  }

  Object _zerosLike(List<int> shape) {
    Object build(int i) => (i == shape.length - 1)
        ? List<double>.filled(shape[i], 0.0)
        : List.generate(shape[i], (_) => build(i + 1), growable: false);
    return build(0);
  }

  Future<void> _handleFrame(Map msg) async {
    try {
      _iouThr = (msg['iou'] as double?) ?? _iouThr;
      _confThr = (msg['conf'] as double?) ?? _confThr;

      final w = msg['w'] as int;
      final h = msg['h'] as int;
      final yRowStride = msg['yRowStride'] as int;
      final uvRowStride = msg['uvRowStride'] as int;
      final uvPixelStride = msg['uvPixelStride'] as int;

      final y = (msg['y'] as TransferableTypedData).materialize().asUint8List();
      final u = (msg['u'] as TransferableTypedData).materialize().asUint8List();
      final v = (msg['v'] as TransferableTypedData).materialize().asUint8List();

      final rgb = _yuv420ToRgb(
        y: y,
        u: u,
        v: v,
        w: w,
        h: h,
        yRowStride: yRowStride,
        uvRowStride: uvRowStride,
        uvPixelStride: uvPixelStride,
      );

      final resized = img.copyResize(
        rgb,
        width: _inW,
        height: _inH,
        interpolation: img.Interpolation.linear,
      );

      final input = _imageToInput(resized, _inType);
      final outT = _interpreter.getOutputTensor(0);
      final oshape = outT.shape;
      final output = _zerosLike(oshape);

      _interpreter.run(input, output);

      List<List<double>> rows;
      if (oshape.length == 2) {
        final n = oshape[0], d = oshape[1];
        rows = List.generate(
          n,
          (i) => List<double>.from(((output as List)[i] as List)
              .take(d)
              .map((e) => (e as num).toDouble())),
        );
      } else if (oshape.length == 3 && oshape[0] == 1) {
        final n = oshape[1], d = oshape[2];
        final out0 = (output as List)[0] as List;
        rows = List.generate(
          n,
          (i) => List<double>.from(((out0[i] as List).take(d))
              .map((e) => (e as num).toDouble())),
        );
      } else {
        rows = const [];
      }

      final parsed = _parseRowsAndNms(rows, _iouThr);
      mainSendPort.send({'type': 'result', 'dets': parsed});
    } catch (e) {
      mainSendPort.send({'type': 'error', 'msg': 'Frame failed: $e'});
    }
  }

  await for (final msg in inbox) {
    if (msg is Map && msg['type'] == 'init') {
      await _handleInit(msg);
    } else if (msg is Map && msg['type'] == 'frame') {
      await _handleFrame(msg);
    }
  }
}
