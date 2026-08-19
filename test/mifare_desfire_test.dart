import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_desfire/general.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DESFire GetVersion identification', () {
    test('recognizes DESFire EV1 and its storage size', () {
      final info = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x01, 0x01, 0x11, 0x00, 0x18, 0x05, 0x91, 0xaf]),
      );

      expect(info.confirmed, isTrue);
      expect(info.generation, 'EV1');
      expect(info.displayName, 'MIFARE DESFire EV1');
      expect(info.storageBytes, 4096);
      expect(info.isExactStorageSize, isTrue);
      expect(info.supportsAes, isTrue);
    });

    test('recognizes implementation and EV generation from nibbles', () {
      final ev2 = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x81, 0x00, 0x22, 0x00, 0x1a, 0x05, 0x91, 0xaf]),
      );
      final ev3 = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x01, 0x00, 0x33, 0x00, 0x1a, 0x05, 0x91, 0xaf]),
      );

      expect(ev2.generation, 'EV2');
      expect(ev3.generation, 'EV3');
      expect(ev2.storageBytes, 8192);
      expect(ev3.supportsAes, isTrue);
    });

    test('recognizes DESFire Light', () {
      final info = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x08, 0x00, 0x10, 0x00, 0x13, 0x05, 0x91, 0xaf]),
      );

      expect(info.confirmed, isTrue);
      expect(info.isLight, isTrue);
      expect(info.displayName, 'MIFARE DESFire Light');
      expect(info.isExactStorageSize, isFalse);
      expect(info.supportsAes, isTrue);
    });

    test('does not confuse DUOX or another Type 4 family with DESFire', () {
      final duox = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x01, 0x00, 0xa0, 0x00, 0x18, 0x05, 0x91, 0xaf]),
      );
      final plus = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x02, 0x00, 0x22, 0x00, 0x18, 0x05, 0x91, 0xaf]),
      );

      expect(duox.confirmed, isFalse);
      expect(plus.confirmed, isFalse);
    });

    test('rejects malformed or unrelated responses', () {
      final short =
          parseMifareDesfireGetVersion(Uint8List.fromList([0x91, 0xaf]));
      final wrongStatus = parseMifareDesfireGetVersion(
        Uint8List.fromList(
            [0x04, 0x01, 0x00, 0x33, 0x00, 0x18, 0x05, 0x6a, 0x82]),
      );

      expect(short.confirmed, isFalse);
      expect(wrongStatus.confirmed, isFalse);
    });
  });
}
