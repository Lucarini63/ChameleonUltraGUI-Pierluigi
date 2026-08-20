import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/slot_card_sync.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  group('automatic slot card synchronization', () {
    test('skips an existing card, imports a missing card, and restores state',
        () async {
      final communicator = _SlotCommunicator(
        activeSlot: 5,
        readerMode: true,
        hfUids: {
          0: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef])
        },
        lfUids: {
          1: Uint8List.fromList([1, 2, 3, 4, 5])
        },
      );
      final existing = CardSave(
        uid: 'de-ad-be-ef',
        name: 'Already saved',
        tag: TagType.mifare1K,
      );

      final result = await importMissingCardsFromSlots(
        communicator: communicator,
        slotTypes: [
          SlotTypes(hf: TagType.mifare1K),
          SlotTypes(lf: TagType.em410X),
        ],
        slotNames: [
          SlotNames(hf: 'Classic'),
          SlotNames(lf: 'Office badge'),
        ],
        savedCards: [existing],
      );

      expect(result.failures, isEmpty);
      expect(result.importedCards, hasLength(1));
      expect(result.importedCards.single.tag, TagType.em410X);
      expect(result.importedCards.single.uid, '01 02 03 04 05');
      expect(result.importedCards.single.name, 'Office badge');
      expect(communicator.classicBlockRequests, isEmpty);
      expect(communicator.activeSlot, 5);
      expect(communicator.readerMode, isTrue);
      expect(communicator.readerModeChanges, [false, true]);
    });

    test('reads a MIFARE Mini dump without requesting blocks past its end',
        () async {
      final communicator = _SlotCommunicator(
        activeSlot: 0,
        readerMode: false,
        hfUids: {
          0: Uint8List.fromList([0xaa, 0xbb, 0xcc, 0xdd])
        },
      );

      final card = await readCardSaveFromActiveSlot(
        communicator: communicator,
        tag: TagType.mifareMini,
        frequency: TagFrequency.hf,
        name: 'Mini',
      );

      expect(card, isNotNull);
      expect(card!.data, hasLength(20));
      expect(communicator.classicBlockRequests, [(0, 16), (16, 4)]);
    });

    test('isolates a slot read failure and still restores device state',
        () async {
      final communicator = _SlotCommunicator(
        activeSlot: 6,
        readerMode: true,
        hfUids: {
          0: Uint8List.fromList([0x11, 0x22, 0x33, 0x44])
        },
        throwOnClassicRead: true,
      );

      final result = await importMissingCardsFromSlots(
        communicator: communicator,
        slotTypes: [SlotTypes(hf: TagType.mifare1K)],
        slotNames: [SlotNames(hf: 'Broken slot')],
        savedCards: [],
      );

      expect(result.importedCards, isEmpty);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.slot, 0);
      expect(result.failures.single.frequency, TagFrequency.hf);
      expect(communicator.activeSlot, 6);
      expect(communicator.readerMode, isTrue);
      expect(communicator.readerModeChanges, [false, true]);
    });
  });
}

class _SlotCommunicator extends ChameleonCommunicator {
  int activeSlot;
  bool readerMode;
  final Map<int, Uint8List> hfUids;
  final Map<int, Uint8List> lfUids;
  final bool throwOnClassicRead;
  final List<bool> readerModeChanges = [];
  final List<(int, int)> classicBlockRequests = [];

  _SlotCommunicator({
    required this.activeSlot,
    required this.readerMode,
    this.hfUids = const {},
    this.lfUids = const {},
    this.throwOnClassicRead = false,
  }) : super(Logger());

  @override
  Future<int> getActiveSlot() async => activeSlot;

  @override
  Future<bool> isReaderDeviceMode() async => readerMode;

  @override
  Future<void> setReaderDeviceMode(bool enabled) async {
    readerMode = enabled;
    readerModeChanges.add(enabled);
  }

  @override
  Future<void> activateSlot(int slot) async {
    activeSlot = slot;
  }

  @override
  Future<CardData> mf1GetAntiCollData() async => CardData(
        uid: hfUids[activeSlot] ?? Uint8List(4),
        sak: 0x08,
        atqa: Uint8List.fromList([0x04, 0x00]),
        ats: Uint8List(0),
      );

  @override
  Future<Uint8List> mf1GetEmulatorBlock(int startBlock, int blockCount) async {
    classicBlockRequests.add((startBlock, blockCount));
    if (throwOnClassicRead) throw StateError('slot read failed');
    return Uint8List.fromList(List.generate(
      blockCount * 16,
      (index) => (startBlock * 16 + index) & 0xff,
    ));
  }

  @override
  Future<Uint8List> getEM410XEmulatorID() async =>
      lfUids[activeSlot] ?? Uint8List(5);
}
