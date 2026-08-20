import 'dart:math' as math;
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

class SlotCardSyncFailure {
  final int slot;
  final TagFrequency frequency;
  final Object error;

  const SlotCardSyncFailure({
    required this.slot,
    required this.frequency,
    required this.error,
  });
}

class SlotCardSyncResult {
  final List<CardSave> importedCards;
  final List<SlotCardSyncFailure> failures;

  const SlotCardSyncResult({
    required this.importedCards,
    required this.failures,
  });
}

String normalizeSavedCardUid(String uid) =>
    uid.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();

bool containsSavedCard(List<CardSave> cards, TagType tag, String uid) {
  final normalizedUid = normalizeSavedCardUid(uid);
  return cards.any(
    (card) =>
        card.tag == tag && normalizeSavedCardUid(card.uid) == normalizedUid,
  );
}

Future<CardSave?> readCardSaveFromActiveSlot({
  required ChameleonCommunicator communicator,
  required TagType tag,
  required TagFrequency frequency,
  required String name,
  CardData? antiCollision,
}) async {
  if (frequency == TagFrequency.lf) {
    if (isEM410X(tag)) {
      return CardSave(
        uid: bytesToHexSpace(await communicator.getEM410XEmulatorID()),
        name: name,
        tag: tag,
      );
    }
    if (tag == TagType.hidProx) {
      return CardSave(
        uid: (await communicator.getHIDProxEmulatorID()).toString(),
        name: name,
        tag: tag,
      );
    }
    if (tag == TagType.viking) {
      return CardSave(
        uid: (await communicator.getVikingEmulatorID()).toString(),
        name: name,
        tag: tag,
      );
    }
    return null;
  }

  if (!isMifareClassic(tag) && !isMifareUltralight(tag)) return null;
  final cardData = antiCollision ?? await communicator.mf1GetAntiCollData();

  if (isMifareUltralight(tag)) {
    final pageCount = mfUltralightGetPagesCount(tag);
    final pages = <Uint8List>[];
    for (var page = 0; page < pageCount; page++) {
      pages.add(await communicator.mf0EmulatorReadPages(page, 1));
    }

    final extraData = CardSaveExtra();
    final version = await communicator.mf0EmulatorGetVersionData();
    if (version.isNotEmpty) extraData.ultralightVersion = version;
    final signature = await communicator.mf0EmulatorGetSignatureData();
    if (signature.isNotEmpty) extraData.ultralightSignature = signature;

    if (mfUltralightHasCounters(tag)) {
      final counters = <int>[];
      for (var index = 0; index < mfUltralightGetCounterCount(tag); index++) {
        counters.add((await communicator.mf0EmulatorGetCounterData(index)).$1);
      }
      if (counters.isNotEmpty) extraData.ultralightCounters = counters;
    }

    return CardSave(
      uid: bytesToHexSpace(cardData.uid),
      name: name,
      sak: cardData.sak,
      atqa: cardData.atqa,
      ats: cardData.ats,
      tag: tag,
      data: pages,
      extraData: extraData,
    );
  }

  final blockCount =
      mfClassicGetBlockCount(chameleonTagTypeGetMfClassicType(tag));
  final blocks = <Uint8List>[];
  const blocksPerRequest = 16;
  for (var startBlock = 0;
      startBlock < blockCount;
      startBlock += blocksPerRequest) {
    final requestedBlocks = math.min(blocksPerRequest, blockCount - startBlock);
    final data =
        await communicator.mf1GetEmulatorBlock(startBlock, requestedBlocks);
    final expectedBytes = requestedBlocks * 16;
    if (data.length != expectedBytes) {
      throw FormatException(
        'Slot MIFARE Classic: ricevuti ${data.length} byte, '
        'attesi $expectedBytes',
      );
    }
    for (var offset = 0; offset < data.length; offset += 16) {
      blocks.add(Uint8List.fromList(data.sublist(offset, offset + 16)));
    }
  }

  return CardSave(
    uid: bytesToHexSpace(cardData.uid),
    name: name,
    sak: cardData.sak,
    atqa: cardData.atqa,
    ats: cardData.ats,
    tag: tag,
    data: blocks,
  );
}

Future<SlotCardSyncResult> importMissingCardsFromSlots({
  required ChameleonCommunicator communicator,
  required List<SlotTypes> slotTypes,
  required List<SlotNames> slotNames,
  required List<CardSave> savedCards,
}) async {
  final imported = <CardSave>[];
  final failures = <SlotCardSyncFailure>[];
  final originalSlot = await communicator.getActiveSlot();
  final wasReaderMode = await communicator.isReaderDeviceMode();

  try {
    if (wasReaderMode) await communicator.setReaderDeviceMode(false);
    final slotCount = math.min(slotTypes.length, slotNames.length);
    for (var slot = 0; slot < slotCount; slot++) {
      await communicator.activateSlot(slot);
      final types = slotTypes[slot];
      final names = slotNames[slot];

      for (final frequency in [TagFrequency.hf, TagFrequency.lf]) {
        final tag = frequency == TagFrequency.hf ? types.hf : types.lf;
        if (tag == TagType.unknown) continue;
        try {
          CardData? antiCollision;
          String? uid;
          if (frequency == TagFrequency.hf &&
              (isMifareClassic(tag) || isMifareUltralight(tag))) {
            antiCollision = await communicator.mf1GetAntiCollData();
            uid = bytesToHexSpace(antiCollision.uid);
            if (containsSavedCard([...savedCards, ...imported], tag, uid)) {
              continue;
            }
          }

          final card = await readCardSaveFromActiveSlot(
            communicator: communicator,
            tag: tag,
            frequency: frequency,
            name: frequency == TagFrequency.hf ? names.hf : names.lf,
            antiCollision: antiCollision,
          );
          if (card != null &&
              !containsSavedCard(
                [...savedCards, ...imported],
                card.tag,
                card.uid,
              )) {
            imported.add(card);
          }
        } catch (error) {
          failures.add(SlotCardSyncFailure(
            slot: slot,
            frequency: frequency,
            error: error,
          ));
        }
      }
    }
  } finally {
    try {
      await communicator.activateSlot(originalSlot);
    } finally {
      if (wasReaderMode) await communicator.setReaderDeviceMode(true);
    }
  }

  return SlotCardSyncResult(importedCards: imported, failures: failures);
}
