import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

/// Resizes and compresses an image file for upload. Returns a new temp file (JPEG).
/// Use [maxWidth]/[maxHeight] to limit dimensions (aspect ratio preserved).
/// [quality] 1–100 for JPEG (e.g. 85).
Future<File> resizeImageFile(
  File file, {
  int maxWidth = 1200,
  int? maxHeight,
  int quality = 85,
}) async {
  final bytes = await file.readAsBytes();
  final image = img.decodeImage(bytes);
  if (image == null) throw Exception('이미지를 읽을 수 없습니다.');

  final resized = img.copyResize(
    image,
    width: maxWidth,
    height: maxHeight,
    maintainAspect: true,
  );
  final encoded = img.encodeJpg(resized, quality: quality);

  final dir = Directory.systemTemp;
  final outPath = path.join(dir.path, 'upload_${DateTime.now().millisecondsSinceEpoch}.jpg');
  final outFile = File(outPath);
  await outFile.writeAsBytes(encoded);
  return outFile;
}
