import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/general.dart';

class LFSniffAnalysis {
  final int sampleCount;
  final double durationMs;
  final int minimum;
  final int maximum;
  final double average;
  final int threshold;
  final int gapSamples;
  final List<LFLevelRun> runs;

  const LFSniffAnalysis({
    required this.sampleCount,
    required this.durationMs,
    required this.minimum,
    required this.maximum,
    required this.average,
    required this.threshold,
    required this.gapSamples,
    required this.runs,
  });

  factory LFSniffAnalysis.fromSamples(Uint8List samples) {
    if (samples.isEmpty) {
      return const LFSniffAnalysis(
        sampleCount: 0,
        durationMs: 0,
        minimum: 0,
        maximum: 0,
        average: 0,
        threshold: 0,
        gapSamples: 0,
        runs: [],
      );
    }

    var minimum = 255;
    var maximum = 0;
    var total = 0;
    for (final sample in samples) {
      minimum = math.min(minimum, sample);
      maximum = math.max(maximum, sample);
      total += sample;
    }
    final average = total / samples.length;
    final threshold = (average / 2).round();
    final start = math.min(200, samples.length);
    final runs = <LFLevelRun>[];
    var gapSamples = 0;
    if (start < samples.length) {
      var low = samples[start] < threshold;
      var runStart = start;
      for (var index = start; index < samples.length; index++) {
        final currentLow = samples[index] < threshold;
        if (currentLow) gapSamples++;
        if (currentLow != low) {
          runs.add(LFLevelRun(
            low: low,
            startSample: runStart,
            length: index - runStart,
          ));
          low = currentLow;
          runStart = index;
        }
      }
      runs.add(LFLevelRun(
        low: low,
        startSample: runStart,
        length: samples.length - runStart,
      ));
    }

    return LFSniffAnalysis(
      sampleCount: samples.length,
      durationMs: samples.length * 0.008,
      minimum: minimum,
      maximum: maximum,
      average: average,
      threshold: threshold,
      gapSamples: gapSamples,
      runs: runs,
    );
  }

  String get levelPreview {
    if (runs.isEmpty) return '';
    return runs.take(256).map((run) => run.low ? '0' : '1').join();
  }
}

class LFLevelRun {
  final bool low;
  final int startSample;
  final int length;

  const LFLevelRun({
    required this.low,
    required this.startSample,
    required this.length,
  });

  double get durationUs => length * 8.0;
}

class HFSniffFrame {
  final int bits;
  final Uint8List data;
  final bool tagToReader;

  const HFSniffFrame({
    required this.bits,
    required this.data,
    required this.tagToReader,
  });

  String get direction => tagToReader ? 'TAG → READER' : 'READER → TAG';
  String get hex => bytesToHexSpace(data).toUpperCase();
  String get description => decodeHFSniffFrame(this);
}

class HFSniffNonce {
  final int uid;
  final int block;
  final String keyType;
  final int nt;
  final int nr;
  final int ar;

  const HFSniffNonce({
    required this.uid,
    required this.block,
    required this.keyType,
    required this.nt,
    required this.nr,
    required this.ar,
  });

  String get groupId => '$uid:$block:$keyType';
  String get signature => '$groupId:$nt:$nr:$ar';
}

List<HFSniffFrame> parseHFSniffFrames(Uint8List input) {
  final frames = <HFSniffFrame>[];
  var offset = 0;
  while (offset + 2 <= input.length) {
    final header = (input[offset] << 8) | input[offset + 1];
    offset += 2;
    final tagToReader = (header & 0x8000) != 0;
    var bits = header & 0x7fff;
    if (bits == 0) break;
    final byteCount = (bits + 7) ~/ 8;
    if (offset + byteCount > input.length) break;
    var data = Uint8List.fromList(input.sublist(offset, offset + byteCount));
    offset += byteCount;

    if (bits >= 8 && bits % 9 == 0) {
      final decoded = <int>[];
      final bitCount = bits ~/ 9;
      for (var byteIndex = 0; byteIndex < bitCount; byteIndex++) {
        var value = 0;
        for (var bit = 0; bit < 8; bit++) {
          final sourceBit = byteIndex * 9 + bit;
          final sourceByte = sourceBit ~/ 8;
          final sourceOffset = sourceBit % 8;
          value |= ((data[sourceByte] >> sourceOffset) & 1) << bit;
        }
        decoded.add(value);
      }
      data = Uint8List.fromList(decoded);
      bits = bitCount * 8;
    }

    frames.add(HFSniffFrame(
      bits: bits,
      data: data,
      tagToReader: tagToReader,
    ));
  }
  return frames;
}

List<HFSniffNonce> extractHFSniffNonces(List<HFSniffFrame> frames) {
  final nonces = <HFSniffNonce>[];
  final seen = <String>{};
  var uid = 0;

  for (var index = 0; index < frames.length; index++) {
    final frame = frames[index];
    final data = frame.data;
    if (data.isEmpty) continue;

    if (!frame.tagToReader &&
        data.length >= 6 &&
        const [0x93, 0x95, 0x97].contains(data[0]) &&
        data[1] == 0x70 &&
        !(data[0] == 0x93 && data[2] == 0x88)) {
      uid = _u32(data.sublist(2, 6));
    }

    if (frame.tagToReader ||
        data.length < 2 ||
        (data[0] != 0x60 && data[0] != 0x61) ||
        index + 2 >= frames.length) {
      continue;
    }

    final nonceFrame = frames[index + 1];
    final readerAnswer = frames[index + 2];
    if (!nonceFrame.tagToReader ||
        nonceFrame.data.length != 4 ||
        readerAnswer.tagToReader ||
        readerAnswer.data.length != 8) {
      continue;
    }

    final nonce = HFSniffNonce(
      uid: uid,
      block: data[1],
      keyType: data[0] == 0x60 ? 'A' : 'B',
      nt: _u32(nonceFrame.data),
      nr: _u32(readerAnswer.data.sublist(0, 4)),
      ar: _u32(readerAnswer.data.sublist(4, 8)),
    );
    if (seen.add(nonce.signature)) nonces.add(nonce);
  }
  return nonces;
}

int _u32(List<int> bytes) {
  var value = 0;
  for (final byte in bytes.take(4)) {
    value = (value << 8) | byte;
  }
  return value;
}

String decodeHFSniffFrame(HFSniffFrame frame) {
  final data = frame.data;
  if (data.isEmpty) return 'Frame vuoto';
  final first = data[0];
  if (frame.bits == 7) {
    if (first == 0x26) return 'REQA';
    if (first == 0x52) return 'WUPA';
    return 'Frame corto';
  }
  if (frame.tagToReader && data.length == 2) return 'ATQA';
  if (frame.tagToReader && data.length == 5) return 'Risposta anticollisione';
  if (!frame.tagToReader && const [0x93, 0x95, 0x97].contains(first)) {
    final level = {0x93: 'CL1', 0x95: 'CL2', 0x97: 'CL3'}[first];
    return data.length > 1 && data[1] == 0x70
        ? 'SELECT $level'
        : 'ANTICOLLISIONE $level';
  }
  if (!frame.tagToReader && first == 0x60) {
    return 'AUTH Key A${data.length > 1 ? ' · blocco ${data[1]}' : ''}';
  }
  if (!frame.tagToReader && first == 0x61) {
    return 'AUTH Key B${data.length > 1 ? ' · blocco ${data[1]}' : ''}';
  }
  if (!frame.tagToReader && first == 0x30) {
    return 'READ${data.length > 1 ? ' · blocco ${data[1]}' : ''}';
  }
  if (!frame.tagToReader && first == 0xa0) {
    return 'WRITE${data.length > 1 ? ' · blocco ${data[1]}' : ''}';
  }
  if (!frame.tagToReader && first == 0xe0) return 'RATS';
  if (!frame.tagToReader && first == 0x50) return 'HALT';
  if (frame.tagToReader && data.length == 4) return 'Nonce / risposta cifrata';
  if (!frame.tagToReader && data.length == 8) return 'NR + AR cifrati';
  return 'ISO14443-A';
}

String formatHexDump(Uint8List data, {int rowSize = 16}) {
  final output = StringBuffer();
  for (var offset = 0; offset < data.length; offset += rowSize) {
    final end = math.min(offset + rowSize, data.length);
    final row = data.sublist(offset, end);
    output.writeln(
        '${offset.toRadixString(16).padLeft(4, '0').toUpperCase()}  ${bytesToHexSpace(Uint8List.fromList(row)).toUpperCase()}');
  }
  return output.toString().trimRight();
}
