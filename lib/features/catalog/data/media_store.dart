import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/api.dart';
import '../../../core/backend/idempotency.dart';

/// Product images (Phase 3 authorization §3, contracts §4; Phase 1 BR-71).
///
/// * Objects live in the private `store-media` bucket at
///   `{store_id}/products/{product_id}/{uuid}.jpg`. Storage policies check
///   that the first segment is a store the seller may edit; another store's
///   prefix is refused by the server, not by this code.
/// * Uploads are JPEG only, at most 2 MiB (bucket limit): photos are
///   re-encoded here first — orientation applied, centre-cropped to 1:1,
///   at most 1600 px, quality 80, and **no metadata** (EXIF and GPS are not
///   copied).
/// * Images are shown through signed URLs valid for one hour, created with
///   the seller's own token (so the read policy applies again).

const mediaBucket = 'store-media';
const maxSourceImageBytes = 10 * 1024 * 1024;
const maxUploadBytes = 2 * 1024 * 1024;
const productImageEdge = 1600;
const signedUrlLifetime = Duration(hours: 1);

String productImagePath(String storeId, String productId) =>
    '$storeId/products/$productId/${newIdempotencyKey()}.jpg';

enum MediaFailure {
  /// Not an image we can read (or HEIC that the device did not convert).
  unsupported,

  /// Larger than 10 MB before compression.
  tooLarge,

  /// The upload did not reach the server or timed out.
  network,

  /// The server refused it (policy, size or type).
  refused,
}

class MediaException implements Exception {
  const MediaException(this.failure);
  final MediaFailure failure;

  @override
  String toString() => 'MediaException(${failure.name})';
}

/// Re-encodes a photo for upload. Runs in a background isolate so large
/// photos never block the interface.
Future<Uint8List> prepareProductImage(Uint8List source) async {
  if (source.lengthInBytes > maxSourceImageBytes) {
    throw const MediaException(MediaFailure.tooLarge);
  }
  final result = await Isolate.run(() => _prepare(source));
  if (result == null) throw const MediaException(MediaFailure.unsupported);
  return result;
}

/// Synchronous core of [prepareProductImage]; exposed for tests.
Uint8List? prepareProductImageSync(Uint8List source) => _prepare(source);

Uint8List? _prepare(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;
  // Apply the camera's orientation, then forget every piece of metadata.
  var image = img.bakeOrientation(decoded);
  final side = image.width < image.height ? image.width : image.height;
  image = img.copyCrop(
    image,
    x: (image.width - side) ~/ 2,
    y: (image.height - side) ~/ 2,
    width: side,
    height: side,
  );
  if (side > productImageEdge) {
    image = img.copyResize(
      image,
      width: productImageEdge,
      height: productImageEdge,
      interpolation: img.Interpolation.average,
    );
  }
  // A fresh image without exif, text chunks or ICC profile.
  final clean = img.Image.from(image)
    ..exif = img.ExifData()
    ..textData = null
    ..iccProfile = null;
  for (final quality in const [80, 70, 60]) {
    final bytes = img.encodeJpg(clean, quality: quality);
    if (bytes.lengthInBytes <= maxUploadBytes) return bytes;
  }
  return null;
}

/// Where photos come from (camera or gallery). The device returns bytes;
/// [prepareProductImage] does the rest.
enum PhotoSource { camera, gallery }

abstract interface class PhotoPicker {
  /// Null when the seller cancelled.
  Future<Uint8List?> pick(PhotoSource source);
}

class DevicePhotoPicker implements PhotoPicker {
  DevicePhotoPicker([ImagePicker? picker]) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    final file = await _picker.pickImage(
      source: source == PhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      // Asking the platform for a bounded JPEG converts HEIC on iOS and keeps
      // memory use reasonable; the final crop and re-encode happen here.
      maxWidth: 3200,
      maxHeight: 3200,
      imageQuality: 95,
      requestFullMetadata: false,
    );
    return file?.readAsBytes();
  }
}

abstract interface class MediaStore {
  /// Uploads [jpeg] to [path] (never overwriting).
  Future<void> upload(String path, Uint8List jpeg);

  /// An image to display for [path], or throws when it cannot be read.
  Future<ImageProvider> image(String path);

  /// Best-effort removal of objects no product references any more. The
  /// server refuses objects that are still referenced; failures are left to
  /// the orphan cleanup.
  Future<void> remove(List<String> paths);
}

class SupabaseMediaStore implements MediaStore {
  SupabaseMediaStore(this._client);

  final SupabaseClient _client;
  final _urls = <String, (String, DateTime)>{};

  StorageFileApi get _bucket => _client.storage.from(mediaBucket);

  @override
  Future<void> upload(String path, Uint8List jpeg) async {
    try {
      await _bucket
          .uploadBinary(
            path,
            jpeg,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              upsert: false,
            ),
          )
          .timeout(const Duration(seconds: 60));
    } on StorageException catch (e) {
      final status = int.tryParse(e.statusCode ?? '');
      throw MediaException(
        status == 401 ? MediaFailure.network : MediaFailure.refused,
      );
    } on TimeoutException {
      throw const MediaException(MediaFailure.network);
    } on Exception {
      throw const MediaException(MediaFailure.network);
    }
  }

  @override
  Future<ImageProvider> image(String path) async {
    final cached = _urls[path];
    final now = DateTime.now();
    if (cached != null && cached.$2.isAfter(now)) {
      return NetworkImage(cached.$1);
    }
    final url = await _bucket
        .createSignedUrl(path, signedUrlLifetime.inSeconds)
        .timeout(apiTimeout);
    // Reuse the same URL for most of its lifetime so the image cache hits.
    _urls[path] = (
      url,
      now.add(signedUrlLifetime - const Duration(minutes: 10)),
    );
    return NetworkImage(url);
  }

  @override
  Future<void> remove(List<String> paths) async {
    if (paths.isEmpty) return;
    try {
      await _bucket.remove(paths).timeout(apiTimeout);
    } on Object {
      // Left for the orphan cleanup (docs/implementation/phase-6, D §5).
    }
    paths.forEach(_urls.remove);
  }
}

final mediaStoreProvider = Provider<MediaStore>(
  (ref) => SupabaseMediaStore(ref.watch(supabaseClientProvider)),
);

final photoPickerProvider = Provider<PhotoPicker>((ref) => DevicePhotoPicker());
