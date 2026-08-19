import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

class SniffingText {
  final bool italian;

  const SniffingText(this.italian);

  String get noDevice => italian
      ? 'Nessun dispositivo connesso. Connetti un Chameleon per catturare, oppure carica un file salvato.'
      : 'No device connected. Connect a Chameleon to capture, or load a saved file.';
  String get captureTimeout =>
      italian ? 'Timeout di cattura (ms)' : 'Capture timeout (ms)';
  String get capture => italian ? 'Cattura' : 'Capture';
  String get capturing => italian ? 'Cattura in corso…' : 'Capturing…';
  String get saveFile => italian ? 'Salva in un file' : 'Save to file';
  String loadFile(String extension) =>
      italian ? 'Carica file .$extension' : 'Load .$extension file';
  String get copyHex => italian ? 'Copia esadecimale' : 'Copy hexadecimal';
  String get close => italian ? 'Chiudi' : 'Close';
  String get summary => italian ? 'Riepilogo' : 'Summary';
  String get waveform => italian ? "Forma d'onda" : 'Waveform';
  String get decoding => italian ? 'Decodifica' : 'Decoding';
  String get hexadecimal => italian ? 'Esadecimale' : 'Hexadecimal';
  String get frames => italian ? 'Frame' : 'Frames';
  String get nonces => 'Nonce';
  String get recovery => italian ? 'Recupero' : 'Recovery';
  String get raw => italian ? 'Grezzo' : 'Raw';
  String get noCapture =>
      italian ? 'Nessuna cattura disponibile.' : 'No capture available.';
  String get unsupportedFirmware => italian
      ? 'Il firmware collegato non espone questo comando. È richiesto il firmware ChameleonUltra v2.2.0 o successivo.'
      : 'The connected firmware does not expose this command. ChameleonUltra firmware v2.2.0 or newer is required.';
  String loaded(int count) =>
      italian ? 'File caricato: $count byte.' : 'File loaded: $count bytes.';
  String captured(int count) => italian
      ? 'Cattura completata: $count byte.'
      : 'Capture complete: $count bytes.';
}

Future<Uint8List?> loadSniffingFile(String extension) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: [extension],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  if (file.bytes != null) return file.bytes!;
  if (file.path != null) return File(file.path!).readAsBytes();
  return null;
}

Future<void> saveSniffingFile(
    Uint8List data, String baseName, String extension) async {
  try {
    await FileSaver.instance.saveAs(
      name: baseName,
      bytes: data,
      ext: extension,
      mimeType: MimeType.other,
    );
  } on UnimplementedError {
    final output = await FilePicker.platform.saveFile(
      fileName: '$baseName.$extension',
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (output != null) await File(output).writeAsBytes(data);
  }
}

class SniffEmptyView extends StatelessWidget {
  final String message;

  const SniffEmptyView(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}

class SniffMetric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const SniffMetric({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: SelectableText(value),
      ),
    );
  }
}

class LFWaveformPainter extends CustomPainter {
  final Uint8List samples;
  final int threshold;
  final Color waveformColor;
  final Color gridColor;
  final Color thresholdColor;

  const LFWaveformPainter({
    required this.samples,
    required this.threshold,
    required this.waveformColor,
    required this.gridColor,
    required this.thresholdColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final y = size.height * index / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var index = 0; index <= 10; index++) {
      final x = size.width * index / 10;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    if (samples.isEmpty) return;
    final thresholdY = size.height - (threshold / 255 * size.height);
    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      Paint()
        ..color = thresholdColor
        ..strokeWidth = 1.5,
    );

    final path = Path();
    final samplesPerPixel = samples.length / size.width;
    for (var x = 0; x < size.width.floor(); x++) {
      final start = (x * samplesPerPixel).floor();
      final end =
          ((x + 1) * samplesPerPixel).ceil().clamp(start + 1, samples.length);
      var total = 0;
      for (var index = start; index < end; index++) {
        total += samples[index];
      }
      final value = total / (end - start);
      final y = size.height - (value / 255 * size.height);
      if (x == 0) {
        path.moveTo(0, y);
      } else {
        path.lineTo(x.toDouble(), y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = waveformColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant LFWaveformPainter oldDelegate) {
    return oldDelegate.samples != samples || oldDelegate.threshold != threshold;
  }
}
