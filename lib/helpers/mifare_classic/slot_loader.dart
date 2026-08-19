import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

Future<void> loadMifareClassicCardToSlot({
  required ChameleonCommunicator communicator,
  required CardSave card,
  required int slot,
  required String fallbackName,
  void Function(double progress)? onProgress,
}) async {
  if (!isMifareClassic(card.tag)) {
    throw ArgumentError('Only MIFARE Classic cards are supported');
  }
  if (slot < 0 || slot > 7) {
    throw RangeError.range(slot, 0, 7, 'slot');
  }

  final isEV1 = chameleonTagSaveCheckForMifareClassicEV1(card);
  final slotTag = isEV1 ? TagType.mifare2K : card.tag;
  final totalBlocks =
      mfClassicGetBlockCount(chameleonTagTypeGetMfClassicType(slotTag));

  await communicator.setReaderDeviceMode(false);
  await communicator.enableSlot(slot, TagFrequency.hf, true);
  await communicator.activateSlot(slot);
  await communicator.setSlotType(slot, slotTag);
  await communicator.setDefaultDataToSlot(slot, slotTag);
  await communicator.setMf1AntiCollision(CardData(
    uid: hexToBytes(card.uid),
    atqa: card.atqa,
    sak: card.sak,
    ats: card.ats,
  ));

  final chunk = <int>[];
  var chunkStart = 0;

  Future<void> flushChunk() async {
    if (chunk.isEmpty) return;
    await communicator.setMf1BlockData(chunkStart, Uint8List.fromList(chunk));
    chunk.clear();
  }

  for (var block = 0; block < totalBlocks; block++) {
    final blockData = block < card.data.length ? card.data[block] : null;
    if (blockData == null || blockData.length != 16) {
      await flushChunk();
    } else {
      if (chunk.isEmpty) {
        chunkStart = block;
      } else if (chunk.length + blockData.length > 128) {
        await flushChunk();
        chunkStart = block;
      }
      chunk.addAll(blockData);
    }

    onProgress?.call((block + 1) / totalBlocks);
    await asyncSleep(1);
  }
  await flushChunk();

  await communicator.setSlotTagName(
    slot,
    card.name.isEmpty ? fallbackName : card.name,
    TagFrequency.hf,
  );
  await communicator.saveSlotData();
  onProgress?.call(1);
}
