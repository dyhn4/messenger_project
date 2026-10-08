import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

// TangoTalk patches (see ../../TANGOTALK_PATCHES.md):
//  - Every operation runs one at a time in this process (load → change → save of the whole file used to
//    overlap and lose one of the changes).
//  - The file is replaced atomically: written to a temporary file, flushed, then moved over the old one
//    (a crash or power loss in the middle of a write used to leave a torn file).
//  - A file that cannot be read is moved aside instead of deleted (it used to wipe every stored key).

@visibleForTesting
extension OptionsExtension on Map<String, String> {
  bool get useBackwardCompatibility =>
      this['useBackwardCompatibility'] != 'false';
}

class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  final FlutterSecureStoragePlatform _backwardCompatible;
  final MapStorage _storage;

  FlutterSecureStorageWindows()
      : this._(
          MethodChannelFlutterSecureStorage(),
          DpapiJsonFileMapStorage(),
        );

  FlutterSecureStorageWindows._(
    this._backwardCompatible,
    this._storage,
  );

  /// Registers this plugin.
  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  static Future<void> _tail = Future<void>.value();

  /// Runs [op] after every operation started before it has finished.
  static Future<T> _serial<T>(Future<T> Function() op) {
    final result = _tail.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) =>
      _serial(() async {
        final map = await _storage.load(options);
        if (map.containsKey(key)) {
          return true;
        }

        if (options.useBackwardCompatibility) {
          return _backwardCompatible.containsKey(key: key, options: options);
        }

        return false;
      });

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) =>
      _serial(() async {
        final map = await _storage.load(options);
        final initialSize = map.length;
        map.remove(key);
        if (map.length != initialSize) {
          await _storage.save(map, options);
        }

        if (options.useBackwardCompatibility) {
          await _backwardCompatible.delete(key: key, options: options);
        }
      });

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      _serial(() async {
        await _storage.clear(options);

        if (options.useBackwardCompatibility) {
          await _backwardCompatible.deleteAll(options: options);
        }
      });

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) =>
      _serial(() async {
        final map = await _storage.load(options);

        var result = map[key];
        if (options.useBackwardCompatibility) {
          if (result == null) {
            final compatible =
                await _backwardCompatible.read(key: key, options: options);
            if (compatible != null) {
              // Write back now, so the value should be retrieved from JSON file next.
              result = map[key] = compatible;
              await _storage.save(map, options);
            }
          }

          // Clear old entry.
          await _backwardCompatible.delete(key: key, options: options);
        }

        return result;
      });

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) =>
      _serial(() async {
        final map = await _storage.load(options);
        if (!options.useBackwardCompatibility) {
          // Just return a map.
          return map;
        }

        final compatible = await _backwardCompatible.readAll(options: options);

        if (compatible.isEmpty) {
          return map;
        }

        for (final entry in compatible.entries) {
          map.putIfAbsent(entry.key, () => entry.value);
        }

        // Write back now, so the value should be retrieved from JSON file next.
        await _storage.save(map, options);

        // Clear old entries.
        await _backwardCompatible.deleteAll(options: options);

        return map;
      });

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) =>
      _serial(() async {
        final map = await _storage.load(options);
        map[key] = value;
        await _storage.save(map, options);

        if (options.useBackwardCompatibility) {
          // Clear old entry.
          unawaited(
            _backwardCompatible
                .delete(key: key, options: options)
                .catchError((Object e) {
              debugPrint('Failed to clear the old entry: $e');
            }),
          );
        }
      });

  // @override
  // Future<bool> isCupertinoProtectedDataAvailable() => Future.value(true);
  //
  // @override
  // Stream<bool> get onCupertinoProtectedDataAvailabilityChanged =>
  //     Stream.value(true);
}

@visibleForTesting
FlutterSecureStorageWindows createFlutterSecureStorageWindows(
  FlutterSecureStoragePlatform backwardCompatible,
  MapStorage mapStorage,
) =>
    FlutterSecureStorageWindows._(backwardCompatible, mapStorage);

@visibleForTesting
abstract class MapStorage {
  FutureOr<Map<String, String>> load(Map<String, String> options);
  FutureOr<void> save(Map<String, String> data, Map<String, String> options);
  FutureOr<void> clear(Map<String, String> options);
}

@visibleForTesting
const String encryptedJsonFileName = 'flutter_secure_storage.dat';

/// The new contents are written here first (followed by the process id), then moved over the real file.
@visibleForTesting
const String temporaryFileSuffix = '.tmp';

/// A file that could not be read is kept under this name (the latest one only).
@visibleForTesting
const String unreadableFileSuffix = '.unreadable';

@visibleForTesting
class DpapiJsonFileMapStorage extends MapStorage {
  DpapiJsonFileMapStorage({this.filePath});

  /// Replaces the default location (tests only).
  @visibleForTesting
  final String? filePath;

  FutureOr<String> _getJsonFilePath() async {
    final override = filePath;
    if (override != null) return override;
    final appDataDirectory = await getApplicationSupportDirectory();

    return path.canonicalize(
      path.join(
        appDataDirectory.path,
        encryptedJsonFileName,
      ),
    );
  }

  @override
  FutureOr<Map<String, String>> load(Map<String, String> options) async {
    final file = File(await _getJsonFilePath());
    if (!(await file.exists())) {
      return {};
    }

    late final Uint8List encryptedText;
    for (var attempt = 1;; attempt++) {
      try {
        encryptedText = await file.readAsBytes();
        break;
      } on FileSystemException catch (e) {
        // The file is really gone (deleted since the exists() call above) — an empty storage.
        if (!(await file.exists())) {
          debugPrint('Reading file has been deleted by another process. $e');
          return {};
        }
        // Something else (an antivirus scan, an indexer, another instance) holds it for a moment.
        // Never treat that as "empty": a write would then replace every stored key with just the
        // one being written. Retry, then fail the operation.
        if (attempt >= 5) rethrow;
        debugPrint('Reading the storage file failed; retrying. $e');
        await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
      }
    }

    late final String plainText;
    try {
      plainText = using((alloc) {
        final Pointer<Uint8> pEncryptedText = alloc(encryptedText.length);
        pEncryptedText
            .asTypedList(encryptedText.length)
            .setAll(0, encryptedText);

        // Specify size of the struct explicitly.
        final Pointer<CRYPT_INTEGER_BLOB> encryptedTextBlob =
            alloc.allocate(sizeOf<CRYPT_INTEGER_BLOB>());
        encryptedTextBlob.ref.cbData = encryptedText.length;
        encryptedTextBlob.ref.pbData = pEncryptedText;

        // Specify size of the struct explicitly.
        final Pointer<CRYPT_INTEGER_BLOB> plainTextBlob =
            alloc.allocate(sizeOf<CRYPT_INTEGER_BLOB>());
        if (CryptUnprotectData(
              encryptedTextBlob,
              nullptr,
              nullptr,
              nullptr,
              nullptr,
              0,
              plainTextBlob,
            ) ==
            0) {
          throw WindowsException(
            GetLastError(),
            message: 'Failure on CryptUnprotectData()',
          );
        }

        if (plainTextBlob.ref.pbData.address == NULL) {
          throw WindowsException(
            ERROR_OUTOFMEMORY,
            message: 'Failure on CryptUnprotectData()',
          );
        }

        try {
          return utf8.decoder.convert(
            plainTextBlob.ref.pbData.asTypedList(plainTextBlob.ref.cbData),
          );
        } finally {
          if (plainTextBlob.ref.pbData.address != NULL) {
            if (LocalFree(plainTextBlob.ref.pbData).address != NULL) {
              debugPrint(
                'load: Failed to LocalFree with: 0x${GetLastError().toHexString(32)}',
              );
            }
          }
        }
      });
    } on FormatException catch (e) {
      // A file content should be malformed.
      await _setAside(file, 'Failed to decrypt data: $e');
      rethrow;
    } on WindowsException catch (e) {
      // A file content should be malformed.
      await _setAside(file, 'Failed to decrypt data: $e');
      rethrow;
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(plainText);
    } on FormatException catch (e) {
      // A file content should be malformed.
      await _setAside(file, 'Failed to parse JSON: $e');
      rethrow;
    }

    if (decoded is! Map) {
      await _setAside(file, 'Failed to parse JSON: Not an object.');
      throw const FormatException('JSON is not an object.');
    }

    return {
      for (final e
          in decoded.entries.where((x) => x.key is String && x.value is String))
        e.key as String: e.value as String,
    };
  }

  /// Moves a file that could not be read out of the way (keeping it, so the keys in it can still be
  /// recovered if the failure was not permanent); deletes it only if it cannot be moved.
  /// The first unreadable file keeps the plain name (it usually holds the original keys); later ones
  /// get a time stamp so they never overwrite it.
  Future<void> _setAside(File file, String reason) async {
    var target = '${file.path}$unreadableFileSuffix';
    if (await File(target).exists()) {
      target = '$target-${DateTime.now().millisecondsSinceEpoch}';
    }
    debugPrint('$reason Moving unreadable file to: $target');
    final error = _moveReplacing(file.path, target, writeThrough: false);
    if (error == 0) return;
    debugPrint('Could not move it (0x${error.toHexString(32)}); deleting it.');
    try {
      await file.delete();
    } on FileSystemException catch (e) {
      debugPrint('Deleting unreadable file failed. $e');
    }
  }

  @override
  FutureOr<void> save(
    Map<String, String> data,
    Map<String, String> options,
  ) async {
    final file = File(await _getJsonFilePath());
    final json = jsonEncode(data);
    final plainText = utf8.encode(json);

    await using<FutureOr<void>>((alloc) async {
      final Pointer<Uint8> pPlainText = alloc(plainText.length);
      pPlainText.asTypedList(plainText.length).setAll(0, plainText);

      // Specify size of the struct explicitly.
      final Pointer<CRYPT_INTEGER_BLOB> plainTextBlob =
          alloc.allocate(sizeOf<CRYPT_INTEGER_BLOB>());
      plainTextBlob.ref.cbData = plainText.length;
      plainTextBlob.ref.pbData = pPlainText;

      // Specify size of the struct explicitly.
      final Pointer<CRYPT_INTEGER_BLOB> encryptedTextBlob =
          alloc.allocate(sizeOf<CRYPT_INTEGER_BLOB>());
      if (CryptProtectData(
            plainTextBlob,
            nullptr,
            nullptr,
            nullptr,
            nullptr,
            0,
            encryptedTextBlob,
          ) ==
          0) {
        throw WindowsException(
          GetLastError(),
          message: 'Failure on CryptProtectData()',
        );
      }

      if (encryptedTextBlob.ref.pbData.address == NULL) {
        throw WindowsException(
          ERROR_OUTOFMEMORY,
          message: 'Failure on CryptProtectData()',
        );
      }

      try {
        final encryptedText = Uint8List.fromList(
          encryptedTextBlob.ref.pbData
              .asTypedList(encryptedTextBlob.ref.cbData),
        );
        await _replaceAtomically(file, encryptedText);
      } finally {
        if (encryptedTextBlob.ref.pbData.address != NULL) {
          if (LocalFree(encryptedTextBlob.ref.pbData).address != NULL) {
            debugPrint(
              'save: Failed to LocalFree with: 0x${GetLastError().toHexString(32)}',
            );
          }
        }
      }
    });
  }

  /// Writes [bytes] to a temporary file next to [file], flushes it to disk, then moves it over [file] in
  /// one step (MoveFileEx with write-through) — [file] always holds either the old or the new contents.
  /// Retries a few times when something (an antivirus scan, an indexer) briefly holds one of the files.
  Future<void> _replaceAtomically(File file, Uint8List bytes) async {
    // One temporary file per process — two app instances must not write into each other's.
    final temporary = File('${file.path}$temporaryFileSuffix$pid');
    for (var attempt = 1;; attempt++) {
      try {
        await file.parent.create(recursive: true);
        await temporary.writeAsBytes(bytes, flush: true);
        final error =
            _moveReplacing(temporary.path, file.path, writeThrough: true);
        if (error == 0) return;
        if (attempt >= 5) {
          throw WindowsException(error, message: 'Failure on MoveFileEx()');
        }
        debugPrint(
          'Replacing the storage file failed (0x${error.toHexString(32)}); retrying.',
        );
      } on FileSystemException catch (e) {
        if (attempt >= 5) rethrow;
        debugPrint('Writing the storage file failed; retrying. $e');
      }
      await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
    }
  }

  /// Moves [from] over [to] (replacing it); 0 on success, otherwise the Win32 error code.
  static int _moveReplacing(
    String from,
    String to, {
    required bool writeThrough,
  }) =>
      using((alloc) {
        final flags = MOVEFILE_REPLACE_EXISTING |
            (writeThrough ? MOVEFILE_WRITE_THROUGH : 0);
        final moved = MoveFileEx(
          from.toNativeUtf16(allocator: alloc),
          to.toNativeUtf16(allocator: alloc),
          flags,
        );
        if (moved != 0) return 0;
        final error = GetLastError();
        // The last error is not guaranteed to survive between FFI calls — never report a failed
        // move as success.
        return error != 0 ? error : ERROR_GEN_FAILURE;
      });

  @override
  FutureOr<void> clear(Map<String, String> options) async {
    final file = File(await _getJsonFilePath());
    if (await file.exists()) {
      try {
        await file.delete();
      } on FileSystemException catch (e) {
        // Another process has been deleted a file or parent directory
        // since previous File.exists() call.
        // We can ignore it.
        debugPrint(
          'Deleting file has been deleted by another process. $e',
        );
      }
    }
  }
}
