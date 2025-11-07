// lib/pages/video_upload.dart
import 'dart:async';
import 'dart:io' show File;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class VideoUpload extends StatefulWidget {
  const VideoUpload({super.key});
  @override
  State<VideoUpload> createState() => _VideoUploadState();
}

class _VideoUploadState extends State<VideoUpload> {
  // ===== CONFIG =====
  static const String kGetUploadUrlEndpoint =
      'https://access-asset-management-h9fmcwbhcwf5h5f7.westus3-01.azurewebsites.net/api/GetUploadUrl?code=FE4jv9j0B73NW9fnfDVl3TnUQZ3FtrbbS9AQ5Iy2flVCAzFuopGLyA==';

  static const String kUploadVideoEndpoint =
      'https://access-asset-management-h9fmcwbhcwf5h5f7.westus3-01.azurewebsites.net/api/UploadVideo?code=cB5FKbgO6xbgb9WE07bOtl3Hr9TtIFRs0DPg_jCExqe3AzFuUr9kRw==';

  // Batch settings
  static const int kBatchSeconds = 300; // 5 minutes
  static const int kInterBatchGapSeconds = 2; // 2s gap
  static const LocationAccuracy kGpsAccuracy = LocationAccuracy.high;

  final _deviceIdCtrl = TextEditingController(text: 'iphone12');

  List<CameraDescription> _cams = [];
  CameraController? _cam;
  bool _ready = false;
  bool _recording = false;
  bool _busy = false;

  // Logging
  final List<String> _log = [];

  // State machine
  Timer? _batchTimer; // counts to 300s
  Timer? _gpsTimer; // fires each 1s
  DateTime? _batchStartUtc;
  String? _currentUploadUrl;
  String? _currentVideoID;
  String? _currentBlobPath;
  String? _currentExpiresUtc;
  String? _currentLocalPath; // file path for the batch being recorded
  int _tRel = 0;

  // Progress & visibility
  int _batchIndex = 0;          // 1-based batch counter
  bool _uploading = false;
  double? _uploadPct;           // 0..100
  String? _lastUploadMsg;       // last upload status/error line

  final List<_BatchMeta> _completedBatches = []; // track completed batches

  // GPS buffer for current batch
  final List<_GpsPoint> _gps = [];

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _bootstrap(); // ask for perms, then init camera
  }

  @override
  void dispose() {
    _cam?.dispose();
    _batchTimer?.cancel();
    _gpsTimer?.cancel();
    super.dispose();
  }

  // ---- ask permissions first, then init camera ----
  Future<void> _bootstrap() async {
    await _ensureAllPerms();
    await _initCamera();
  }

  Future<void> _ensureAllPerms() async {
    if (!_isMobile) return;

    // Request camera + (optional) location if you want GPS
    final statuses = await [
      Permission.camera,
      Permission.locationWhenInUse, // remove if you don't want GPS
    ].request();

    final camGranted = statuses[Permission.camera]?.isGranted ?? false;
    if (!camGranted) {
      _appendLog('Camera permission not granted.');
      if (statuses[Permission.camera]?.isPermanentlyDenied == true) {
        _appendLog('Open settings to enable Camera permission.');
        await openAppSettings();
      }
    }

    // Location services must also be ON for Geolocator to return points
    final locGranted =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;
    if (locGranted) {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _appendLog('Location services are disabled.');
      }
    } else {
      _appendLog('Location permission not granted (GPS will be empty).');
    }
  }

  Future<void> _initCamera() async {
    if (!_isMobile) {
      _appendLog('Recording supported on Android/iOS only.');
      return;
    }

    // Sanity check: only proceed if camera is granted
    final camStatus = await Permission.camera.status;
    if (!camStatus.isGranted) {
      _appendLog('Init aborted: camera permission still denied.');
      return;
    }

    try {
      _cams = await availableCameras();
      final back = _cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cams.first,
      );
      _cam = CameraController(
        back,
        ResolutionPreset.medium, // keep file sizes reasonable
        enableAudio: false, // no mic
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cam!.initialize();
      setState(() => _ready = true);
      _appendLog('Camera ready (${back.name})');
    } catch (e) {
      _appendLog('Init error: $e');
    }
  }

  // ========== RECORD FLOW ==========
  Future<void> _onStart() async {
    if (!_ready || _cam == null) {
      _appendLog('Camera not ready.');
      return;
    }
    final deviceId = _deviceIdCtrl.text.trim();
    if (deviceId.isEmpty) {
      _appendLog('Enter deviceId first.');
      return;
    }
    if (_recording) return;

    setState(() {
      _recording = true;
      _completedBatches.clear();
      _batchIndex = 0;
    });

    // Kick off the first batch
    await _startNewBatch();
  }

  Future<void> _startNewBatch() async {
    if (!_recording) return;

    _batchIndex += 1;

    // 1) Mint SAS for this batch
    final deviceId = _deviceIdCtrl.text.trim();
    setState(() => _busy = true);
    try {
      final r = await http.post(
        Uri.parse(kGetUploadUrlEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'deviceId': deviceId}),
      );
      if (r.statusCode != 200) {
        throw Exception('GetUploadUrl failed: ${r.statusCode} ${r.body}');
      }
      final m = jsonDecode(r.body) as Map<String, dynamic>;
      _currentVideoID = m['videoID'] as String?;
      _currentBlobPath = m['blobPath'] as String?;
      _currentUploadUrl = m['uploadUrl'] as String?;
      _currentExpiresUtc = m['expiresUtc'] as String?;
      if (_currentVideoID == null ||
          _currentUploadUrl == null ||
          _currentBlobPath == null) {
        throw Exception('Incomplete SAS payload.');
      }
      _appendLog('Batch $_batchIndex: SAS minted • videoID=${_currentVideoID!}');

      // 2) Start camera recording
      _gps.clear();
      _tRel = 0;
      _batchStartUtc = DateTime.now().toUtc();

      try {
        await _cam!.startVideoRecording();
      } on CameraException catch (e) {
        final msg = '${e.code} ${e.description ?? ''}'.toLowerCase();
        // Some ROMs require RECORD_AUDIO even with enableAudio=false
        if (msg.contains('record_audio') || msg.contains('audio')) {
          _appendLog(
              'Device requires mic permission even with enableAudio=false. Requesting…');
          final mic = await Permission.microphone.request();
          if (mic.isGranted) {
            _appendLog('Mic granted (still recording silent). Retrying…');
            await _cam!.startVideoRecording();
          } else {
            _appendLog(
                'Mic permission denied; cannot start video on this device without it.');
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      _appendLog('Batch $_batchIndex: recording started (t=0)');

      // 3) Start timers: 300s batch timer + 1s GPS sampler
      _batchTimer?.cancel();
      _batchTimer = Timer(Duration(seconds: kBatchSeconds), () async {
        await _finishCurrentBatchAndMaybeContinue();
      });

      _gpsTimer?.cancel();
      _gpsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        await _sampleGps();
      });
    } catch (e) {
      _appendLog('Start batch error: $e');
      await _forceStopAll();
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sampleGps() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: kGpsAccuracy,
      );
      _gps.add(_GpsPoint(
        lat: pos.latitude,
        lon: pos.longitude,
        tRelSec: _tRel,
      ));
      _tRel += 1;
    } catch (e) {
      if (_tRel % 10 == 0) _appendLog('GPS sample error (t=$_tRel): $e');
      _tRel += 1;
    }
  }

  Future<void> _finishCurrentBatchAndMaybeContinue() async {
    if (_cam == null || !_cam!.value.isRecordingVideo) return;

    _gpsTimer?.cancel();
    _batchTimer?.cancel();

    XFile? xfile;
    try {
      xfile = await _cam!.stopVideoRecording();
      _currentLocalPath = xfile.path;
    } catch (e) {
      _appendLog('Stop batch error: $e');
      return;
    }

    final startUtc = _batchStartUtc ?? DateTime.now().toUtc();
    final durationSec = _tRel; // how many 1s ticks we actually did

    final file = File(xfile.path);
    final sizeMb = (await file.length()) / (1024 * 1024);
    _appendLog(
        'Batch $_batchIndex: stopped • ${xfile.name} ~${durationSec}s (${sizeMb.toStringAsFixed(2)} MB)');

    try {
      await _uploadBlobViaSas(_currentUploadUrl!, file);
      _appendLog('Batch $_batchIndex: blob uploaded for ${_currentVideoID!}');

      final gpsJson = _gps
          .map((p) => {'lat': p.lat, 'lon': p.lon, 'tRelSec': p.tRelSec})
          .toList();

      final payload = {
        'videoID': _currentVideoID!,
        'blobPath': _currentBlobPath!,
        'startUtc': startUtc.toIso8601String(),
        'durationSec': durationSec,
        'deviceId': _deviceIdCtrl.text.trim(),
        'gps': gpsJson,
      };

      final finalize = await http.post(
        Uri.parse(kUploadVideoEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (finalize.statusCode != 200) {
        _appendLog(
            'UploadVideo FAILED: ${finalize.statusCode} ${finalize.body}');
        throw Exception(
            'UploadVideo failed: ${finalize.statusCode} ${finalize.body}');
      }
      _appendLog('Batch $_batchIndex: UploadVideo finalized ${_currentVideoID!}');

      _completedBatches.add(_BatchMeta(
        videoID: _currentVideoID!,
        startUtc: startUtc,
        durationSec: durationSec,
        blobPath: _currentBlobPath!,
        localPath: _currentLocalPath!,
      ));
    } catch (e) {
      _appendLog('Batch $_batchIndex: finalize failed: $e');
    }

    if (_recording) {
      _appendLog('Inter-batch gap ${kInterBatchGapSeconds}s…');
      await Future.delayed(const Duration(seconds: kInterBatchGapSeconds));
      await _startNewBatch();
    }
  }

  Future<void> _onStop() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _busy = true;
    });

    _gpsTimer?.cancel();
    _batchTimer?.cancel();

    if (_cam != null && _cam!.value.isRecordingVideo) {
      await _finishCurrentBatchAndMaybeContinue();
    }

    setState(() => _busy = false);
    _appendLog('All batches finalized. Recording stopped.');
  }

  Future<void> _forceStopAll() async {
    _gpsTimer?.cancel();
    _batchTimer?.cancel();
    if (_cam != null && _cam!.value.isRecordingVideo) {
      try {
        await _cam!.stopVideoRecording();
      } catch (_) {}
    }
    setState(() => _recording = false);
  }

  // ===== Blob upload (SAS URL) =====
  Future<void> _uploadBlobViaSas(String sasUrl, File f) async {
    _uploading = true;
    _uploadPct = 0;
    _lastUploadMsg = 'Uploading...';
    setState(() {});

    final dio = Dio(BaseOptions(
      headers: {
        'x-ms-blob-type': 'BlockBlob', // required for simple block blob
        'Content-Type': 'video/mp4',
      },
      connectTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(minutes: 10),
      receiveTimeout: const Duration(minutes: 5),
    ));

    try {
      final len = await f.length();
      await dio.put(
        sasUrl,
        data: f.openRead(), // stream – avoids loading full file into RAM
        options: Options(
          // Dio 5.x: no contentLength param; set header instead
          headers: {'Content-Length': len.toString()},
          validateStatus: (code) => code != null && code >= 200 && code < 400,
        ),
        onSendProgress: (sent, total) {
          if (total > 0) {
            _uploadPct = (sent / total) * 100;
          } else {
            // sometimes 'total' is 0; fall back to known file size
            _uploadPct = (sent / len) * 100;
          }
          setState(() {});
        },
      );
      _lastUploadMsg = 'Upload OK (${_uploadPct?.toStringAsFixed(0)}%)';
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final body = e.response?.data?.toString();
      _lastUploadMsg = 'Upload FAILED [${code ?? '-'}] ${body ?? ''}';
      _appendLog('Blob PUT failed: code=$code body=${body ?? ''}');
      rethrow;
    } catch (e) {
      _lastUploadMsg = 'Upload error: $e';
      _appendLog('Blob PUT error: $e');
      rethrow;
    } finally {
      _uploading = false;
      setState(() {});
    }
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('5-Minute Batch Recorder')),
      body: !_isMobile
          ? const Center(child: Text('Use Android/iOS device for recording.'))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _deviceIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'deviceId',
                            hintText: 'e.g., iphone12',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _recording
                          ? FilledButton.icon(
                              onPressed: _busy ? null : _onStop,
                              icon: const Icon(Icons.stop),
                              label: const Text('Stop'),
                            )
                          : FilledButton.icon(
                              onPressed:
                                  (_ready && !_busy) ? _onStart : null,
                              icon: const Icon(Icons.fiber_manual_record),
                              label: const Text('Start'),
                            ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Preview
                  if (_ready && _cam != null)
                    AspectRatio(
                      aspectRatio: _cam!.value.aspectRatio,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CameraPreview(_cam!),
                      ),
                    )
                  else
                    Container(
                      height: 200,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: cs.surfaceVariant.withOpacity(.35),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('Camera not ready'),
                    ),

                  const SizedBox(height: 12),

                  // Current batch info
                  Card(
                    elevation: 1,
                    child: ListTile(
                      leading: const Icon(Icons.timelapse),
                      title: Text(_currentVideoID == null
                          ? 'No active batch'
                          : 'Active videoID: $_currentVideoID'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_currentUploadUrl == null
                              ? 'Press Start to begin 5-min batches'
                              : 'blob: ${_currentBlobPath ?? '-'}\n'
                                'expires: ${_currentExpiresUtc ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Batch: $_batchIndex  •  Elapsed: ${_fmt(_tRel)} / 05:00  •  GPS: ${_gps.length} pts'),
                          if (_uploading || _lastUploadMsg != null) ...[
                            const SizedBox(height: 6),
                            if (_uploading && _uploadPct != null)
                              LinearProgressIndicator(value: (_uploadPct!.clamp(0, 100)) / 100),
                            Text(
                              _uploading
                                ? 'Uploading… ${_uploadPct?.toStringAsFixed(0) ?? ''}%'
                                : (_lastUploadMsg ?? ''),
                              style: TextStyle(
                                fontSize: 12,
                                color: _uploading ? Colors.orange : Colors.green,
                              ),
                            ),
                          ],
                        ],
                      ),
                      isThreeLine: true,
                    ),
                  ),

                  const SizedBox(height: 8),
                  // Completed batches (brief)
                  if (_completedBatches.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Completed: ${_completedBatches.length} batch(es). '
                        'Last: ${_completedBatches.last.durationSec}s • ${_completedBatches.last.blobPath}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),

                  const SizedBox(height: 8),

                  // Logs
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.surfaceVariant.withOpacity(.25),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListView.builder(
                        reverse: true,
                        itemCount: _log.length,
                        itemBuilder: (_, i) => Text(
                          _log[_log.length - 1 - i],
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  void _appendLog(String s) {
    final t = DateTime.now()
        .toLocal()
        .toIso8601String()
        .split('T')
        .last
        .split('.')
        .first;
    setState(() => _log.add('[$t] $s'));
  }
}

// ===== Helpers / Models =====
class _GpsPoint {
  final double lat, lon;
  final int tRelSec;
  _GpsPoint({required this.lat, required this.lon, required this.tRelSec});
}

class _BatchMeta {
  final String videoID;
  final DateTime startUtc;
  final int durationSec;
  final String blobPath;
  final String localPath;
  _BatchMeta({
    required this.videoID,
    required this.startUtc,
    required this.durationSec,
    required this.blobPath,
    required this.localPath,
  });
}
