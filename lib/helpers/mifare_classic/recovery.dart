import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/recovery/recovery.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';

// Recovery
import 'package:chameleonultragui/recovery/recovery.dart' as recovery;

extension PartitionList<E> on List<E> {
  List<List<E>> partition(int size) {
    assert(size > 0);
    final out = <List<E>>[];
    for (var i = 0; i < length; i += size) {
      final end = i + size < length ? i + size : length;
      out.add(sublist(i, end));
    }
    return out;
  }
}

enum ChameleonKeyCheckmark { none, found, checking, disabled }

class MifareClassicRecoveryCancelled implements Exception {}

enum MifareClassicAttackMethod {
  darkside,
  nested,
  staticNested,
  hardNested,
  backdoor,
}

class MifareClassicAttackPlan {
  NTLevel prng;
  final bool hasBackdoor;
  final int foundKeys;
  final int missingKeys;
  final List<MifareClassicAttackMethod> steps;
  MifareClassicAttackMethod? currentStep;

  MifareClassicAttackPlan({
    required this.prng,
    required this.hasBackdoor,
    required this.foundKeys,
    required this.missingKeys,
    required this.steps,
    this.currentStep,
  });
}

MifareClassicAttackPlan buildMifareClassicAttackPlan({
  required NTLevel prng,
  required bool hasBackdoor,
  required bool isStaticEncrypted,
  required int foundKeys,
  required int missingKeys,
}) {
  final steps = <MifareClassicAttackMethod>[];
  MifareClassicAttackMethod? recoveryMethod;

  switch (prng) {
    case NTLevel.static:
      recoveryMethod = MifareClassicAttackMethod.staticNested;
    case NTLevel.weak:
      recoveryMethod = MifareClassicAttackMethod.nested;
    case NTLevel.hard:
      recoveryMethod = MifareClassicAttackMethod.hardNested;
    case NTLevel.backdoor:
      recoveryMethod = MifareClassicAttackMethod.backdoor;
    case NTLevel.unknown:
      break;
  }

  if (missingKeys > 0) {
    if (isStaticEncrypted) {
      if (hasBackdoor) {
        steps.add(MifareClassicAttackMethod.backdoor);
      }
    } else if (foundKeys > 0 && recoveryMethod != null) {
      steps.add(recoveryMethod);
    } else if (foundKeys == 0 && prng != NTLevel.static) {
      steps.add(MifareClassicAttackMethod.darkside);
      if (hasBackdoor && prng == NTLevel.weak) {
        steps.add(MifareClassicAttackMethod.backdoor);
      }
      if (recoveryMethod != null) {
        steps.add(recoveryMethod);
      }
    }
  }

  return MifareClassicAttackPlan(
    prng: prng,
    hasBackdoor: hasBackdoor,
    foundKeys: foundKeys,
    missingKeys: missingKeys,
    steps: steps.toSet().toList(),
  );
}

class MifareClassicRecovery {
  late ChameleonGUIState appState;
  late AppLocalizations localizations;
  String error;
  String state;
  bool allKeysExists;
  List<Dictionary> dictionaries;
  Dictionary? selectedDictionary;
  List<ChameleonKeyCheckmark> checkMarks;
  List<Uint8List> validKeys;
  List<Uint8List> cardData;
  List<bool> cardDataRead;
  double dumpProgress;
  double? hardnestedProgress;
  double? keyCheckProgress;
  double? recoveryProgress;
  void Function() update;
  MifareClassicType mifareClassicType;
  bool isMifareClassicEV1;
  bool cancellationRequested = false;
  NTLevel? detectedNtLevel;
  bool? detectedHasBackdoor;
  MifareClassicAttackPlan? attackPlan;

  MifareClassicRecovery(
      {required this.appState,
      required this.update,
      required this.localizations,
      this.error = '',
      this.state = '',
      this.allKeysExists = false,
      this.dictionaries = const [],
      this.dumpProgress = 0,
      this.selectedDictionary,
      this.mifareClassicType = MifareClassicType.none,
      this.isMifareClassicEV1 = false,
      this.detectedNtLevel,
      this.detectedHasBackdoor,
      List<ChameleonKeyCheckmark>? checkMarks,
      List<Uint8List>? validKeys,
      List<Uint8List>? cardData,
      List<bool>? cardDataRead})
      : checkMarks =
            checkMarks ?? List.generate(80, (_) => ChameleonKeyCheckmark.none),
        validKeys = validKeys ?? List.generate(80, (_) => Uint8List(0)),
        cardData = cardData ?? List.generate(256, (_) => Uint8List(0)),
        cardDataRead = cardDataRead ?? List.filled(256, false) {
    initializeEV1();
  }

  void resetCancellation() {
    cancellationRequested = false;
  }

  void requestCancellation() {
    cancellationRequested = true;
    update();
  }

  void _throwIfCancellationRequested() {
    if (cancellationRequested) {
      throw MifareClassicRecoveryCancelled();
    }
  }

  Future<bool> checkKeysOnSector(List<Uint8List> keys, int keyType, int sector,
      {bool showBasicProgress = true}) async {
    if (showBasicProgress) {
      state = localizations.checking_keys(keys.length);
    }
    Uint8List? key;
    if (showBasicProgress) {
      keyCheckProgress = null;
    }
    int chunkSize =
        appState.connector!.connectionType == ConnectionType.ble ? 32 : 64;

    if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
        getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
      setCheckingSector(sector, keyType);
      int totalChunks = keys.partition(chunkSize).length;

      for (var chunk in keys.partition(chunkSize)) {
        _throwIfCancellationRequested();
        key = await appState.communicator!.mf1AuthMultipleKeys(
            mfClassicGetSectorTrailerBlockBySector(sector),
            0x60 + keyType,
            chunk);
        _throwIfCancellationRequested();
        if (key != null) {
          setKeyAsFound(sector, keyType, key);
          if (showBasicProgress) {
            keyCheckProgress = null;
          }
          await recheckKey(key, sector);
          return true;
        } else if (showBasicProgress && totalChunks > 10) {
          keyCheckProgress = (keyCheckProgress ?? 0) + 1 / totalChunks;
          update();
        }
      }

      if (key == null) {
        setMissingSector(sector, keyType);
      }
    }

    if (keyType == 0 &&
        getSectorState(sector, 0) == ChameleonKeyCheckmark.found &&
        getSectorState(sector, 1) != ChameleonKeyCheckmark.found &&
        getSectorState(sector, 1) != ChameleonKeyCheckmark.disabled &&
        key != null) {
      Uint8List block = await appState.communicator!.mf1ReadBlock(
          mfClassicGetSectorTrailerBlockBySector(sector), 0x60 + keyType, key);
      if (block.length == 16) {
        Uint8List bKey = block.sublist(10);
        if (bytesToHex(bKey) != bytesToHex(Uint8List(6))) {
          if (showBasicProgress) {
            keyCheckProgress = null;
          }
          await recheckKey(bKey, sector);
          return true;
        }
      }
    }

    setMissingSector(sector, keyType);
    if (showBasicProgress) {
      keyCheckProgress = null;
    }
    return false;
  }

  Future<void> initialize() async {
    if (!await appState.communicator!.isReaderDeviceMode()) {
      await appState.communicator!.setReaderDeviceMode(true);
    }

    var mifare = await appState.communicator!.detectMf1Support();

    if (mifare) {
      mifareClassicType = await mfClassicGetType(appState.communicator!);
    } else {
      appState.log!.e("Not Mifare Classic tag!");
    }

    isMifareClassicEV1 =
        await appState.communicator!.mf1Auth(0x45, 0x61, gMifareClassicKeys[3]);
    initializeEV1();
  }

  Future<void> recheckKey(Uint8List key, int startingSector) async {
    for (var sector = startingSector;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        _throwIfCancellationRequested();
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
          state = localizations.checking_keys(1);
          appState.log!.d(
              "Checking found key ${bytesToHex(key)} on sector $sector, key type $keyType");
          setCheckingSector(sector, keyType);

          if (await appState.communicator!.mf1Auth(
              mfClassicGetSectorTrailerBlockBySector(sector),
              0x60 + keyType,
              key)) {
            // Found valid key
            setKeyAsFound(sector, keyType, key);
          } else {
            setMissingSector(sector, keyType);
          }

          _throwIfCancellationRequested();
          update();
        }
      }
    }
  }

  void initializeEV1() {
    if (isMifareClassicEV1) {
      setKeyAsFound(16, 0, gMifareClassicKeys[4]); // MFC EV1 SIGNATURE 16 A
      setKeyAsFound(16, 1, gMifareClassicKeys[5]); // MFC EV1 SIGNATURE 16 B
      setKeyAsFound(17, 0, gMifareClassicKeys[6]); // MFC EV1 SIGNATURE 17 A
      setKeyAsFound(17, 1, gMifareClassicKeys[3]); // MFC EV1 SIGNATURE 17 B
    }
  }

  Future<void> checkKeys({bool skipDefaultDictionary = false}) async {
    _throwIfCancellationRequested();
    initializeEV1();

    final keyList = <Uint8List>[];
    final seenKeys = <String>{};

    void addUniqueKeys(Iterable<Uint8List> keys) {
      for (final key in keys) {
        if (seenKeys.add(bytesToHex(key))) {
          keyList.add(key);
        }
      }
    }

    addUniqueKeys(selectedDictionary!.keys);
    if (!skipDefaultDictionary) {
      addUniqueKeys(gMifareClassicKeys);
    }
    final chunkSize =
        appState.connector!.connectionType == ConnectionType.ble ? 32 : 64;
    final keyChunks = keyList.partition(chunkSize);
    final sectorCount =
        mfClassicGetSectorCount(mifareClassicType, isEV1: isMifareClassicEV1);
    final totalChecks = keyChunks.length * sectorCount * 2;
    var completedChecks = 0;

    // Walk through the selected dictionary only once. Each chunk is checked
    // against every unresolved sector/key type before moving to the next one;
    // the dictionary therefore never starts again from its first key.
    for (var chunkIndex = 0; chunkIndex < keyChunks.length; chunkIndex++) {
      final chunk = keyChunks[chunkIndex];
      for (var sector = 0; sector < sectorCount; sector++) {
        for (var keyType = 0; keyType < 2; keyType++) {
          _throwIfCancellationRequested();
          state = '${localizations.checking_keys(chunk.length)} • '
              '${localizations.sector} $sector/${sectorCount - 1} • '
              '${localizations.key} ${keyType == 0 ? 'A' : 'B'} • '
              '${chunkIndex + 1}/${keyChunks.length}';
          keyCheckProgress =
              totalChecks == 0 ? null : completedChecks / totalChecks;
          update();

          await checkKeysOnSector(chunk, keyType, sector,
              showBasicProgress: false);
          completedChecks++;
          keyCheckProgress =
              totalChecks == 0 ? null : completedChecks / totalChecks;
          update();
        }
      }
    }

    _throwIfCancellationRequested();

    // Key check part competed, checking found keys
    allKeysExists = true;
    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
            getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
          allKeysExists = false;
        }
      }
    }

    keyCheckProgress = null;
    state = "";
    update();
  }

  Future<void> recoverKeys() async {
    _throwIfCancellationRequested();
    recoveryProgress = 0;
    state = localizations.checking_card_info;
    update();

    error = "";
    bool hasKey = false;
    bool hasBackdoor = detectedHasBackdoor ??
        await mfClassicHasBackdoor(appState.communicator!);
    detectedHasBackdoor = hasBackdoor;
    _throwIfCancellationRequested();
    (int, NestedNonces, NestedNonces, Uint8List)? backdoorInfo;

    DarksideResult darkside = DarksideResult.fixed;
    Uint8List planningKey = Uint8List(0);
    int planningKeyBlock = 0;
    int planningKeyType = -1;
    for (var sector = 0;
        sector <
                mfClassicGetSectorCount(mifareClassicType,
                    isEV1: isMifareClassicEV1) &&
            !hasKey;
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.found) {
          hasKey = true;
          planningKey = getSectorKey(sector, keyType);
          planningKeyBlock = mfClassicGetSectorTrailerBlockBySector(sector);
          planningKeyType = keyType;
          break;
        }
      }
    }

    update();

    bool isStaticEncrypted = false;
    bool staticEncryptedChecked = false;

    if (hasKey) {
      isStaticEncrypted = await mfClassicIsStaticEncrypted(
          appState.communicator!,
          planningKeyBlock,
          planningKeyType,
          planningKey);
      staticEncryptedChecked = true;
      _throwIfCancellationRequested();
    } else if (hasBackdoor) {
      backdoorInfo = await appState.communicator!
          .getMf1StaticEncryptedNestedAcquire(
              sectorCount: mfClassicGetSectorCount(mifareClassicType,
                  isEV1: isMifareClassicEV1));
      _throwIfCancellationRequested();
      isStaticEncrypted = await mfClassicIsStaticEncrypted(
          appState.communicator!, 0, 4, backdoorInfo!.$4);
      staticEncryptedChecked = true;
      _throwIfCancellationRequested();
    }

    if (isStaticEncrypted && hasBackdoor && backdoorInfo == null) {
      backdoorInfo = await appState.communicator!
          .getMf1StaticEncryptedNestedAcquire(
              sectorCount: mfClassicGetSectorCount(mifareClassicType,
                  isEV1: isMifareClassicEV1));
      _throwIfCancellationRequested();
    }

    NTLevel prng =
        detectedNtLevel ?? await appState.communicator!.getMf1NTLevel();
    detectedNtLevel = prng;
    _throwIfCancellationRequested();

    final sectorCount =
        mfClassicGetSectorCount(mifareClassicType, isEV1: isMifareClassicEV1);
    final foundKeys = checkMarks
            .take(sectorCount)
            .where((mark) => mark == ChameleonKeyCheckmark.found)
            .length +
        checkMarks
            .skip(40)
            .take(sectorCount)
            .where((mark) => mark == ChameleonKeyCheckmark.found)
            .length;
    final disabledKeys = checkMarks
            .take(sectorCount)
            .where((mark) => mark == ChameleonKeyCheckmark.disabled)
            .length +
        checkMarks
            .skip(40)
            .take(sectorCount)
            .where((mark) => mark == ChameleonKeyCheckmark.disabled)
            .length;
    final missingKeys = sectorCount * 2 - foundKeys - disabledKeys;

    attackPlan = buildMifareClassicAttackPlan(
      prng: prng,
      hasBackdoor: hasBackdoor,
      isStaticEncrypted: isStaticEncrypted,
      foundKeys: foundKeys,
      missingKeys: missingKeys,
    );
    appState.log?.i('[MFC-PLANNER] PRNG ${prng.name}, '
        'backdoor $hasBackdoor, found $foundKeys, missing $missingKeys, '
        'route ${attackPlan!.steps.map((step) => step.name).join(' -> ')}');
    update();

    if (missingKeys == 0) {
      allKeysExists = true;
      recoveryProgress = null;
      state = "";
      update();
      return;
    }

    if (attackPlan!.steps.isEmpty) {
      error = hasKey
          ? localizations.recovery_error_no_supported
          : localizations.recovery_error_no_keys_darkside;
      recoveryProgress = null;
      state = "";
      appState.log?.w('[MFC-PLANNER] recovery stopped: no supported route');
      update();
      return;
    }

    if (!hasKey && !isStaticEncrypted && prng != NTLevel.static) {
      attackPlan?.currentStep = MifareClassicAttackMethod.darkside;
      state = localizations.checking_or_running_darkside;
      update();

      try {
        setCheckingSector(0, 1);
        darkside = await appState.communicator!.checkMf1Darkside();
        _throwIfCancellationRequested();
      } catch (_) {
        _throwIfCancellationRequested();
        setMissingSector(0, 1);
      }

      if (darkside == DarksideResult.vulnerable) {
        // recover with darkside
        var data =
            await appState.communicator!.getMf1Darkside(0x03, 0x61, true, 15);
        var darkside = DarksideDart(uid: data.uid, items: []);
        bool found = false;
        update();

        for (var tries = 0; tries < 5 && !found; tries++) {
          _throwIfCancellationRequested();
          darkside.items.add(DarksideItemDart(
              nt1: data.nt1,
              ks1: data.ks1,
              par: data.par,
              nr: data.nr,
              ar: data.ar));

          var keys = await recovery.darkside(darkside);
          _throwIfCancellationRequested();
          if (keys.isNotEmpty) {
            appState.log!.d("Darkside: Found keys: $keys. Checking them...");

            if (await checkKeysOnSector(mfClassicConvertKeys(keys), 1, 0)) {
              found = true;
              hasKey = true;

              break;
            }
          } else {
            appState.log!.d("Can't find keys, retrying...");
            data = await appState.communicator!
                .getMf1Darkside(0x03, 0x61, false, 15);
          }
        }

        if (!found) {
          setMissingSector(0, 1);
        }
      }
    }

    update();

    if (!hasKey && hasBackdoor && prng == NTLevel.weak && !isStaticEncrypted) {
      attackPlan?.currentStep = MifareClassicAttackMethod.backdoor;
      state = localizations.backdoor_recovery_of_non_static_encrypted;
      setCheckingSector(0, 0);

      for (var i = 0; i < 3; i++) {
        _throwIfCancellationRequested();
        NTDistance distance = await appState.communicator!
            .getMf1NTDistance(0, 0x64, backdoorInfo!.$4);
        _throwIfCancellationRequested();

        NestedNonces nonces = await appState.communicator!
            .getMf1NestedNonces(0, 0x64, backdoorInfo.$4, 0, 0x60, level: prng);
        _throwIfCancellationRequested();

        var nested = NestedDart(
            uid: distance.uid,
            distance: distance.distance,
            nt0: nonces.nonces[0].nt,
            nt0Enc: nonces.nonces[0].ntEnc,
            par0: nonces.nonces[0].parity,
            nt1: nonces.nonces[1].nt,
            nt1Enc: nonces.nonces[1].ntEnc,
            par1: nonces.nonces[1].parity);

        List<int> keys = await recovery.nested(nested);

        if (keys.isNotEmpty) {
          appState.log!.d("Found keys: $keys. Checking them...");
          if (await checkKeysOnSector(mfClassicConvertKeys(keys), 0, 0)) {
            break;
          }
        }
      }
    }

    Uint8List validKey = Uint8List(0);
    int validKeyBlock = 0;
    int validKeyType = -1;

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.found) {
          validKey = getSectorKey(sector, keyType);
          validKeyBlock = mfClassicGetSectorTrailerBlockBySector(sector);
          validKeyType = keyType;
          if (!staticEncryptedChecked) {
            isStaticEncrypted = await mfClassicIsStaticEncrypted(
                appState.communicator!, validKeyBlock, validKeyType, validKey);
            staticEncryptedChecked = true;
            _throwIfCancellationRequested();
          }
          break;
        }
      }
    }

    if ((isStaticEncrypted || (validKeyType == -1 && hasBackdoor)) &&
        backdoorInfo != null) {
      prng = NTLevel.backdoor;
      attackPlan?.prng = prng;
      if (!(attackPlan?.steps.contains(MifareClassicAttackMethod.backdoor) ??
          false)) {
        attackPlan?.steps.add(MifareClassicAttackMethod.backdoor);
      }
    }

    if (validKeyType == -1 && prng != NTLevel.backdoor) {
      error = localizations.recovery_error_no_keys_darkside;
      recoveryProgress = null;
      attackPlan?.currentStep = null;
      state = "";
      appState.log?.w('[MFC-RECOVERY] automatic recovery stopped: '
          'no valid base key and Darkside did not provide one');
      update();
      return;
    }

    if (validKeyType != -1) {
      appState.log?.i('[MFC-RECOVERY] valid base key available on '
          'sector ${mfClassicGetSectorByBlock(validKeyBlock)}, '
          'type ${validKeyType == 0 ? 'A' : 'B'}; continuing with recovery');
    }

    int tries = [NTLevel.backdoor, NTLevel.static].contains(prng) ? 1 : 5;
    final recoverySectorCount =
        mfClassicGetSectorCount(mifareClassicType, isEV1: isMifareClassicEV1);

    for (var sector = 0; sector < recoverySectorCount; sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        _throwIfCancellationRequested();
        if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
          String attackType;

          switch (prng) {
            case NTLevel.static:
              attackType = "Static Nested";
              attackPlan?.currentStep = MifareClassicAttackMethod.staticNested;
            case NTLevel.weak:
              attackType = "Nested";
              attackPlan?.currentStep = MifareClassicAttackMethod.nested;
            case NTLevel.hard:
              attackType = "Hard Nested";
              attackPlan?.currentStep = MifareClassicAttackMethod.hardNested;
            case NTLevel.backdoor:
              attackType = localizations.has_backdoor_support;
              attackPlan?.currentStep = MifareClassicAttackMethod.backdoor;
            case NTLevel.unknown:
              attackType = "";
          }

          recoveryProgress = (sector * 2 + keyType) / (recoverySectorCount * 2);
          state = '${localizations.collecting_nonces(attackType)} • '
              '${localizations.sector} $sector/${recoverySectorCount - 1} • '
              '${localizations.key} ${keyType == 0 ? 'A' : 'B'}';
          setCheckingSector(sector, keyType);

          NTDistance? distance;
          NestedNonces? nonces;

          if (prng != NTLevel.backdoor) {
            distance = await appState.communicator!
                .getMf1NTDistance(validKeyBlock, 0x60 + validKeyType, validKey);
          }

          bool found = false;
          for (var i = 0; i < tries && !found; i++) {
            _throwIfCancellationRequested();
            List<int> keys = [];

            if (prng == NTLevel.hard) {
              hardnestedProgress = 0;
              update();

              var result = await collectHardnestedNonces(
                  validKeyBlock,
                  0x60 + validKeyType,
                  validKey,
                  mfClassicGetSectorTrailerBlockBySector(sector),
                  0x60 + keyType);

              if (result is String) {
                setMissingSector(sector, keyType);
                error = result;
                return;
              } else {
                nonces = result as NestedNonces;
              }
            } else if (prng != NTLevel.backdoor) {
              nonces = await appState.communicator!.getMf1NestedNonces(
                  validKeyBlock,
                  0x60 + validKeyType,
                  validKey,
                  mfClassicGetSectorTrailerBlockBySector(sector),
                  0x60 + keyType,
                  level: prng);
            }

            state = '${localizations.recovering_key(attackType)} • '
                '${localizations.sector} $sector/${recoverySectorCount - 1} • '
                '${localizations.key} ${keyType == 0 ? 'A' : 'B'}';
            update();
            _throwIfCancellationRequested();

            if (prng == NTLevel.weak) {
              var nested = NestedDart(
                  uid: distance!.uid,
                  distance: distance.distance,
                  nt0: nonces!.nonces[0].nt,
                  nt0Enc: nonces.nonces[0].ntEnc,
                  par0: nonces.nonces[0].parity,
                  nt1: nonces.nonces[1].nt,
                  nt1Enc: nonces.nonces[1].ntEnc,
                  par1: nonces.nonces[1].parity);

              keys = await recovery.nested(nested);
            } else if (prng == NTLevel.static) {
              var nested = StaticNestedDart(
                uid: distance!.uid,
                keyType: 0x60 + validKeyType,
                nt0: nonces!.nonces[0].nt,
                nt0Enc: nonces.nonces[0].ntEnc,
                nt1: nonces.nonces[1].nt,
                nt1Enc: nonces.nonces[1].ntEnc,
              );

              keys = await recovery.staticNested(nested);
            } else if (prng == NTLevel.hard) {
              var nested =
                  HardNestedDart(nonces: nonces!.getHardNested(distance!.uid));
              keys = await recovery.hardNested(nested);
            } else if (prng == NTLevel.backdoor) {
              setCheckingSector(sector, 1);

              var possibleAKeys = await recovery.staticEncryptedNested(
                  StaticEncryptedNestedDart(
                      uid: backdoorInfo!.$1,
                      nt: backdoorInfo.$2.nonces[sector].nt,
                      ntEnc: backdoorInfo.$2.nonces[sector].ntEnc,
                      ntParEnc: backdoorInfo.$2.nonces[sector].parity));

              var possibleBKeys = await recovery.staticEncryptedNested(
                  StaticEncryptedNestedDart(
                      uid: backdoorInfo.$1,
                      nt: backdoorInfo.$3.nonces[sector].nt,
                      ntEnc: backdoorInfo.$3.nonces[sector].ntEnc,
                      ntParEnc: backdoorInfo.$3.nonces[sector].parity));

              var filtered = await StaticEncryptedKeysFilterAsync.filterKeys(
                  possibleAKeys,
                  possibleBKeys,
                  backdoorInfo.$2.nonces[sector].nt,
                  backdoorInfo.$3.nonces[sector].nt);

              if (await checkKeysOnSector(
                  mfClassicConvertKeys(filtered.$2.reversed.toList()),
                  1,
                  sector)) {
                checkMarks[sector + 40] = ChameleonKeyCheckmark.found;
                if (await checkKeysOnSector(
                    mfClassicConvertKeys(
                        await StaticEncryptedKeysFilterAsync.findMatchingKeys(
                            backdoorInfo.$3.nonces[sector].nt,
                            bytesToU64(Uint8List.fromList(
                                [0, 0, ...validKeys[sector + 40]])),
                            backdoorInfo.$2.nonces[sector].nt,
                            possibleAKeys)),
                    0,
                    sector)) {
                  found = true;
                  break;
                } else if (await checkKeysOnSector(
                    mfClassicConvertKeys(filtered.$1.reversed.toList()),
                    0,
                    sector)) {
                  found = true;
                  break;
                }
              }

              setMissingSector(sector, 0);
              setMissingSector(sector, 1);
            }

            if (keys.isNotEmpty) {
              appState.log!.d("Found keys: $keys. Checking them...");

              if (await checkKeysOnSector(
                  mfClassicConvertKeys(keys), keyType, sector)) {
                found = true;

                break;
              }
            } else {
              appState.log!.e("Can't find keys, retrying...");
            }
          }
        }
      }
    }

    recoveryProgress = null;
    attackPlan?.currentStep = null;
    state = "";
    allKeysExists = true;
    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var keyType = 0; keyType < 2; keyType++) {
        if (getSectorState(sector, keyType) != ChameleonKeyCheckmark.found &&
            getSectorState(sector, keyType) != ChameleonKeyCheckmark.disabled) {
          allKeysExists = false;
        }
      }
    }
    update();
  }

  Future<void> dumpData() async {
    cardData = List.generate(256, (_) => Uint8List(0));
    cardDataRead = List.filled(256, false);

    for (var sector = 0;
        sector <
            mfClassicGetSectorCount(mifareClassicType,
                isEV1: isMifareClassicEV1);
        sector++) {
      for (var block = 0;
          block < mfClassicGetBlockCountBySector(sector);
          block++) {
        for (var keyType = 0; keyType < 2; keyType++) {
          appState.log!
              .d("Dumping sector $sector, block $block with key $keyType");

          if (getSectorKey(sector, keyType).isEmpty) {
            appState.log!.w("Skipping missing key");
            cardData[block + mfClassicGetFirstBlockCountBySector(sector)] =
                Uint8List(16);
            continue;
          }

          var blockData = await appState.communicator!.mf1ReadBlock(
              block + mfClassicGetFirstBlockCountBySector(sector),
              0x60 + keyType,
              getSectorKey(sector, keyType));
          final blockRead = blockData.isNotEmpty;

          if (blockData.isEmpty) {
            if (keyType == 1) {
              blockData = Uint8List(16);
            } else {
              continue;
            }
          }

          if (mfClassicGetSectorTrailerBlockBySector(sector) ==
              block + mfClassicGetFirstBlockCountBySector(sector)) {
            // set keys in sector trailer
            if (getSectorKey(sector, 0).isNotEmpty) {
              blockData.setRange(0, 6, getSectorKey(sector, 0));
            }

            if (getSectorKey(sector, 1).isNotEmpty) {
              blockData.setRange(10, 16, getSectorKey(sector, 1));
            }
          }

          final blockIndex =
              block + mfClassicGetFirstBlockCountBySector(sector);
          cardData[blockIndex] = blockData;
          cardDataRead[blockIndex] = blockRead;

          dumpProgress = (block + mfClassicGetFirstBlockCountBySector(sector)) /
              (mfClassicGetBlockCount(mifareClassicType));

          update();

          break;
        }
      }
    }
  }

  Future<dynamic> collectHardnestedNonces(int block, int keyType,
      Uint8List knownKey, int targetBlock, int targetKeyType) async {
    NestedNonces nonces = NestedNonces(nonces: []);
    while (true) {
      _throwIfCancellationRequested();
      var collectedNonces = await appState.communicator!.getMf1NestedNonces(
          block, keyType, knownKey, targetBlock, targetKeyType,
          level: NTLevel.hard);
      _throwIfCancellationRequested();
      nonces.nonces.addAll(collectedNonces.nonces);
      List info = nonces.getNoncesInfo();
      appState.log!.d(
          "Collected ${nonces.nonces.length} nonces, sum ${info[0]}, num ${info[1]}");

      if (nonces.nonces.isEmpty) {
        return localizations.recovery_old_firmware;
      }

      hardnestedProgress = info[1] / 256;
      state = localizations.hardnested_collecting_nonces(
          (hardnestedProgress! * 256).toInt().toString());
      update();
      if (info[1] == 256) {
        if ([
          0,
          32,
          56,
          64,
          80,
          96,
          104,
          112,
          120,
          128,
          136,
          144,
          152,
          160,
          176,
          192,
          200,
          224,
          256
        ].contains(info[0])) {
          break;
        }

        appState.log!.e("Got wrong sum, trying to collect nonces again...");
        nonces.nonces = [];
      }
    }

    hardnestedProgress = null;
    return nonces;
  }

  void setKeyAsFound(int sector, int keyType, Uint8List key) {
    checkMarks[sector + (keyType * 40)] = ChameleonKeyCheckmark.found;
    validKeys[sector + (keyType * 40)] = key;
    update();
  }

  void setCheckingSector(int sector, int keyType) {
    if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.none) {
      checkMarks[sector + (keyType * 40)] = ChameleonKeyCheckmark.checking;
    }
    update();
  }

  void setMissingSector(int sector, int keyType) {
    if (getSectorState(sector, keyType) == ChameleonKeyCheckmark.checking) {
      checkMarks[sector + (keyType * 40)] = ChameleonKeyCheckmark.none;
      update();
    }
  }

  Uint8List getSectorKey(int sector, int keyType) {
    return validKeys[sector + (keyType * 40)];
  }

  ChameleonKeyCheckmark getSectorState(int sector, int keyType) {
    return checkMarks[sector + (keyType * 40)];
  }
}
