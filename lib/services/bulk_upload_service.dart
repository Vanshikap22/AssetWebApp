// lib/services/bulk_upload_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

/// Bulk upload images to Azure Function.
/// Payload shape:
/// {
///   "images": [ { "image": "<base64>" }, { "image": "<base64>" } ]
/// }
class BulkUploadService {
  static const String _endpoint =
      'https://access-asset-management-h9fmcwbhcwf5h5f7.westus3-01.azurewebsites.net/api/BulkSignageImages?code=sug-lC4QTgDRgdoohvxDyZkfOaCbuyV07gKSaniOKAzmAzFunUn8ng==';

  static Future<({bool ok, String msg, int count})> pickAndUpload() async {
    final picker = ImagePicker();
    final picks = await picker.pickMultiImage(imageQuality: 100);
    if (picks.isEmpty) {
      return (ok: false, msg: 'No images selected', count: 0);
    }
    return uploadFiles(picks);
  }

  static Future<({bool ok, String msg, int count})> uploadFiles(
    List<XFile> files,
  ) async {
    if (files.isEmpty) {
      return (ok: false, msg: 'No files to upload', count: 0);
    }

    try {
      final images = <Map<String, String>>[];

      for (final f in files) {
        final bytes = await f.readAsBytes();
        final b64 = base64Encode(bytes);
        images.add({'image': b64});
      }

      final body = jsonEncode({'images': images});
      final resp = await http.post(
        Uri.parse(_endpoint),
        headers: const {'Content-Type': 'application/json'},
        body: body,
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return (ok: true, msg: 'Uploaded ${files.length} images', count: files.length);
      } else {
        final reason = resp.body.isNotEmpty ? resp.body : 'HTTP ${resp.statusCode}';
        return (ok: false, msg: 'Upload failed: $reason', count: 0);
      }
    } catch (e) {
      return (ok: false, msg: 'Network error: $e', count: 0);
    }
  }
}
