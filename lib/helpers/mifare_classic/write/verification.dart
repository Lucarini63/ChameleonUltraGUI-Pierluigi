import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class MifareClassicCloneVerification {
  final bool cardDetected;
  final bool uidMatches;
  final List<int> differentBlocks;
  final List<int> unreadableBlocks;
  final List<int> missingDumpBlocks;
  final List<String> keyMismatches;

  const MifareClassicCloneVerification({
    required this.cardDetected,
    required this.uidMatches,
    required this.differentBlocks,
    required this.unreadableBlocks,
    required this.missingDumpBlocks,
    required this.keyMismatches,
  });

  bool get isIdentical =>
      cardDetected &&
      uidMatches &&
      differentBlocks.isEmpty &&
      unreadableBlocks.isEmpty &&
      missingDumpBlocks.isEmpty &&
      keyMismatches.isEmpty;
}

Future<MifareClassicCloneVerification> verifyMifareClassicClone({
  required ChameleonCommunicator communicator,
  required CardSave expected,
  void Function(int checkedBlocks, int totalBlocks)? onProgress,
}) async {
  final type = chameleonTagTypeGetMfClassicType(expected.tag);
  final totalBlocks = mfClassicGetBlockCount(type);
  final differentBlocks = <int>[];
  final unreadableBlocks = <int>[];
  final missingDumpBlocks = <int>[];
  final keyMismatches = <String>[];

  final detectedCard = await communicator.scan14443aTag();
  if (detectedCard == null) {
    return MifareClassicCloneVerification(
      cardDetected: false,
      uidMatches: false,
      differentBlocks: differentBlocks,
      unreadableBlocks: unreadableBlocks,
      missingDumpBlocks: missingDumpBlocks,
      keyMismatches: keyMismatches,
    );
  }

  final uidMatches =
      bytesToHex(detectedCard.uid) == bytesToHex(hexToBytes(expected.uid));
  var checkedBlocks = 0;

  for (var sector = 0; sector < mfClassicGetSectorCount(type); sector++) {
    final firstBlock = mfClassicGetFirstBlockCountBySector(sector);
    final blockCount = mfClassicGetBlockCountBySector(sector);
    final trailerBlock = mfClassicGetSectorTrailerBlockBySector(sector);

    final trailerAvailable = trailerBlock < expected.data.length &&
        expected.data[trailerBlock].length == 16;
    if (!trailerAvailable) {
      for (var offset = 0; offset < blockCount; offset++) {
        final block = firstBlock + offset;
        if (block < totalBlocks) missingDumpBlocks.add(block);
      }
      checkedBlocks += blockCount;
      onProgress?.call(checkedBlocks, totalBlocks);
      continue;
    }

    final expectedTrailer = expected.data[trailerBlock];
    final keyA = Uint8List.fromList(expectedTrailer.sublist(0, 6));
    final keyB = Uint8List.fromList(expectedTrailer.sublist(10, 16));
    var keyAValid = false;
    var keyBValid = false;

    try {
      keyAValid = await communicator.mf1Auth(trailerBlock, 0x60, keyA);
    } catch (_) {}
    try {
      keyBValid = await communicator.mf1Auth(trailerBlock, 0x61, keyB);
    } catch (_) {}

    if (!keyAValid) keyMismatches.add('${sector + 1}A');
    if (!keyBValid) keyMismatches.add('${sector + 1}B');

    for (var offset = 0; offset < blockCount; offset++) {
      final block = firstBlock + offset;
      if (block >= totalBlocks) break;

      if (block >= expected.data.length || expected.data[block].length != 16) {
        missingDumpBlocks.add(block);
        checkedBlocks++;
        onProgress?.call(checkedBlocks, totalBlocks);
        continue;
      }

      Uint8List actual = Uint8List(0);
      if (keyAValid) {
        try {
          actual = await communicator.mf1ReadBlock(block, 0x60, keyA);
        } catch (_) {}
      }
      if (actual.length != 16 && keyBValid) {
        try {
          actual = await communicator.mf1ReadBlock(block, 0x61, keyB);
        } catch (_) {}
      }

      if (actual.length != 16) {
        unreadableBlocks.add(block);
      } else if (block == trailerBlock) {
        if (!_sameBytes(
            actual.sublist(6, 10), expected.data[block].sublist(6, 10))) {
          differentBlocks.add(block);
        }
      } else if (!_sameBytes(actual, expected.data[block])) {
        differentBlocks.add(block);
      }

      checkedBlocks++;
      onProgress?.call(checkedBlocks, totalBlocks);
    }
  }

  return MifareClassicCloneVerification(
    cardDetected: true,
    uidMatches: uidMatches,
    differentBlocks: differentBlocks,
    unreadableBlocks: unreadableBlocks,
    missingDumpBlocks: missingDumpBlocks,
    keyMismatches: keyMismatches,
  );
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
