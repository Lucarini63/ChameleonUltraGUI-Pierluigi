import 'dart:typed_data';

import 'package:chameleonultragui/helpers/sniffing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LF sniff analysis', () {
    test('computes levels, duration and field gaps', () {
      final samples = Uint8List.fromList([
        ...List<int>.filled(200, 160),
        ...List<int>.filled(10, 160),
        ...List<int>.filled(5, 10),
        ...List<int>.filled(10, 160),
      ]);

      final analysis = LFSniffAnalysis.fromSamples(samples);

      expect(analysis.sampleCount, 225);
      expect(analysis.durationMs, closeTo(1.8, 0.0001));
      expect(analysis.minimum, 10);
      expect(analysis.maximum, 160);
      expect(analysis.gapSamples, 5);
      expect(analysis.runs.length, 3);
      expect(analysis.levelPreview, '101');
    });
  });

  group('HF sniff parsing', () {
    test('parses frame direction and payload', () {
      final frames = parseHFSniffFrames(
        Uint8List.fromList([
          0x00,
          0x07,
          0x26,
          0x80,
          0x10,
          0x04,
          0x00,
        ]),
      );

      expect(frames, hasLength(2));
      expect(frames[0].tagToReader, isFalse);
      expect(frames[0].description, 'REQA');
      expect(frames[1].tagToReader, isTrue);
      expect(frames[1].description, 'ATQA');
    });

    test('extracts complete MIFARE authentication records', () {
      final frames = <HFSniffFrame>[
        HFSniffFrame(
          bits: 72,
          data:
              Uint8List.fromList([0x93, 0x70, 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0]),
          tagToReader: false,
        ),
        HFSniffFrame(
          bits: 32,
          data: Uint8List.fromList([0x60, 0x08, 0, 0]),
          tagToReader: false,
        ),
        HFSniffFrame(
          bits: 32,
          data: Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
          tagToReader: true,
        ),
        HFSniffFrame(
          bits: 64,
          data: Uint8List.fromList(
              [0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC]),
          tagToReader: false,
        ),
      ];

      final nonces = extractHFSniffNonces(frames);

      expect(nonces, hasLength(1));
      expect(nonces.single.uid, 0xDEADBEEF);
      expect(nonces.single.block, 8);
      expect(nonces.single.keyType, 'A');
      expect(nonces.single.nt, 0x11223344);
      expect(nonces.single.nr, 0x55667788);
      expect(nonces.single.ar, 0x99AABBCC);
    });
  });
}
