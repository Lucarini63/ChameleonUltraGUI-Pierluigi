import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Plain text log file living next to the app data.
///
/// The shared preferences logger is tied to the debug page and is easy to lose,
/// which makes it awkward to look at a card read that already happened. The
/// same lines are written here to a file that survives the session, so a read
/// and the dictionaries it used can be inspected afterwards.
class FileLog {
  static const currentFileName = 'chameleon-latest.log';
  static const previousFileName = 'chameleon-previous.log';

  /// The current file is rotated once over this size and a single previous file
  /// is kept: two full card reads with serial logging fit comfortably.
  static const _maxBytes = 4 * 1024 * 1024;

  /// The printer is configured without colors, but a stray escape sequence from
  /// somewhere else must not end up in the file.
  static final _ansiEscape = RegExp('\x1B\\[[0-9;]*m');

  static File? _file;
  static IOSink? _sink;
  static int _bytes = 0;
  static bool _rotating = false;

  /// Path of the file being written, null when no file could be opened.
  static String? get path => _file?.path;

  static bool get isActive => _sink != null;

  /// Opens the log file. Failures are swallowed on purpose: a read-only or
  /// sandboxed filesystem must never keep the app from starting, it only means
  /// there is no log file this run.
  static Future<void> init() async {
    if (_sink != null) return;

    try {
      final directory = Directory(
          p.join((await getApplicationSupportDirectory()).path, 'logs'));
      await directory.create(recursive: true);

      final file = File(p.join(directory.path, currentFileName));
      _file = file;
      _bytes = (await file.exists()) ? await file.length() : 0;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend, encoding: utf8);

      if (_bytes > _maxBytes) {
        await _rotate();
      }
    } catch (_) {
      _file = null;
      _sink = null;
    }
  }

  static void write(Iterable<String> lines) {
    final sink = _sink;
    if (sink == null) return;

    try {
      for (final line in lines) {
        final clean = line.replaceAll(_ansiEscape, '');
        sink.writeln(clean);
        _bytes += clean.length + 1;
      }
    } catch (_) {
      return;
    }

    if (_bytes > _maxBytes && !_rotating) {
      _rotating = true;
      // Fire and forget: the rotation detaches the sink first, so whatever is
      // logged while it runs is dropped instead of landing in a file that is
      // being renamed.
      _rotate().whenComplete(() => _rotating = false);
    }
  }

  /// Writes a line that does not come from the logger, timestamped the same way
  /// the printer timestamps its own lines.
  static void note(String line) {
    write(['${DateTime.now().toIso8601String()} $line']);
  }

  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// Reads the log back, keeping only the tail when it is larger than
  /// [maxBytes] — the interesting part of a diagnostic run is always the end.
  static Future<String> read({int maxBytes = 512 * 1024}) async {
    await flush();

    final file = _file;
    if (file == null || !await file.exists()) return '';

    final length = await file.length();
    if (length <= maxBytes) {
      return file.readAsString();
    }

    final handle = await file.open();
    try {
      await handle.setPosition(length - maxBytes);
      final bytes = await handle.read(maxBytes);
      return '[... truncated, showing the last ${maxBytes ~/ 1024} KB '
          'of ${length ~/ 1024} KB]\n'
          '${utf8.decode(bytes, allowMalformed: true)}';
    } finally {
      await handle.close();
    }
  }

  static Future<void> clear() async {
    final file = _file;
    if (file == null) return;

    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    await _reopen(file);
  }

  static Future<void> _rotate() async {
    final file = _file;
    if (file == null) return;

    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();

      final previous = File(p.join(file.parent.path, previousFileName));
      if (await previous.exists()) {
        await previous.delete();
      }
      await file.rename(previous.path);
    } catch (_) {
      // A failed rotation must not lose the live log: fall through and keep
      // appending to whatever is still there.
    }

    await _reopen(file);
  }

  static Future<void> _reopen(File file) async {
    try {
      _bytes = (await file.exists()) ? await file.length() : 0;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend, encoding: utf8);
    } catch (_) {
      _sink = null;
    }
  }
}

class FileLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    FileLog.write(event.lines);
  }
}

/// One timestamped line per log entry.
///
/// PrettyPrinter spreads a single entry over the caller stack frames, a line
/// with the time and a line with the message, which makes the log file three
/// times longer and impossible to filter by tag. Here every line carries its
/// own timestamp and level, so `[MFC-CHECK]` can be grepped straight out of the
/// file. Stack traces are still printed in full, but only for errors.
class PlainLogPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) {
    final prefix = '${event.time.toIso8601String()} '
        '${event.level.name.toUpperCase().padRight(7)}';

    final output = <String>[
      for (final line in event.message.toString().split('\n')) '$prefix $line',
    ];

    final error = event.error;
    if (error != null) {
      for (final line in error.toString().split('\n')) {
        output.add('$prefix $line');
      }
    }

    final stackTrace = event.stackTrace;
    if (stackTrace != null) {
      output.addAll(stackTrace.toString().trimRight().split('\n'));
    }

    return output;
  }
}
