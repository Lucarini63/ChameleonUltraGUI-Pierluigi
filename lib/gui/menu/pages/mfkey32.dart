import 'dart:async';

import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/dialogs/dictionary/export.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_classic/slot_loader.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/recovery/recovery.dart';
import 'package:chameleonultragui/recovery/recovery.dart' as recovery;
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class Mfkey32Menu extends StatefulWidget {
  final int? slot;

  const Mfkey32Menu({super.key, this.slot});

  @override
  State<Mfkey32Menu> createState() => Mfkey32MenuState();
}

class Mfkey32MenuState extends State<Mfkey32Menu> {
  static const int _maxPairsPerAnalysisBatch = 32;
  static const Duration _analysisPairTimeout = Duration(seconds: 20);

  Timer? _pollTimer;
  ChameleonGUIState? _appState;
  bool _wasConnected = false;
  int _sessionGeneration = 0;
  bool _checkingSlot = true;
  bool _slotCompatible = false;
  bool _collecting = false;
  bool _analyzing = false;
  bool _polling = false;
  bool _hasStarted = false;
  bool _restartFromZeroRequired = false;
  int _detectionCount = 0;
  int _usableGroups = 0;
  int _completedPairs = 0;
  int _totalPairs = 0;
  int _lastAnalyzedCount = -1;
  String? _error;
  String _status = '';
  bool _readingCard = false;
  bool _uploadingCard = false;
  double? _workflowProgress;
  int _readBlocks = 0;
  int _totalBlocks = 0;
  int? _emulationSlot;
  CardSave? _savedCard;
  bool _dumpComplete = false;
  int? _detectedSlotIndex;
  MifareClassicRecovery? _activeCardRecovery;
  final Set<String> _attemptedPairs = {};
  final List<_RecoveredMfkey32Key> _results = [];

  Mfkey32Text get text =>
      Mfkey32Text(Localizations.localeOf(context).languageCode == 'it');
  int get _slotIndex => widget.slot ?? _detectedSlotIndex ?? 7;
  int get _slotNumber => _slotIndex + 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _inspectSlot());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = context.read<ChameleonGUIState>();
    if (!identical(_appState, appState)) {
      _appState?.removeListener(_handleConnectionChange);
      _appState = appState;
      _wasConnected = appState.connector?.connected ?? false;
      appState.addListener(_handleConnectionChange);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _appState?.removeListener(_handleConnectionChange);
    super.dispose();
  }

  bool get _isDeviceConnected => _appState?.connector?.connected ?? false;

  bool _isCurrentSession(int generation) =>
      mounted && generation == _sessionGeneration && _isDeviceConnected;

  void _handleConnectionChange() {
    final connected = _isDeviceConnected;
    if (_wasConnected && !connected) {
      _resetAfterDisconnect();
    }
    _wasConnected = connected;
  }

  void _resetAfterDisconnect() {
    if (!mounted) return;
    _pollTimer?.cancel();
    _sessionGeneration++;
    setState(() {
      _checkingSlot = false;
      _slotCompatible = false;
      _collecting = false;
      _analyzing = false;
      _polling = false;
      _hasStarted = false;
      _restartFromZeroRequired = true;
      _detectionCount = 0;
      _usableGroups = 0;
      _completedPairs = 0;
      _totalPairs = 0;
      _lastAnalyzedCount = -1;
      _error = null;
      _status = text.deviceDisconnected;
      _readingCard = false;
      _uploadingCard = false;
      _workflowProgress = null;
      _readBlocks = 0;
      _totalBlocks = 0;
      _emulationSlot = null;
      _savedCard = null;
      _dumpComplete = false;
      _detectedSlotIndex = null;
      _activeCardRecovery = null;
      _attemptedPairs.clear();
      _results.clear();
    });
  }

  Future<void> _inspectSlot() async {
    if (!mounted) return;
    if (!_isDeviceConnected) {
      _resetAfterDisconnect();
      return;
    }
    final generation = ++_sessionGeneration;
    setState(() {
      _checkingSlot = true;
      _error = null;
      _status = widget.slot == null
          ? text.searchingActiveCollection
          : text.checkingSlot(_slotNumber);
    });

    try {
      final appState = context.read<ChameleonGUIState>();
      final communicator = appState.communicator!;
      final slots = await communicator.getSlotTagTypes();
      if (!_isCurrentSession(generation)) return;
      var selectedSlot = widget.slot;
      var compatible = false;
      var collectionActive = false;

      if (selectedSlot != null) {
        compatible = selectedSlot >= 0 &&
            selectedSlot < slots.length &&
            isMifareClassic(slots[selectedSlot].hf);
        if (compatible) {
          final originalSlot = await communicator.getActiveSlot();
          final wasReaderMode = await communicator.isReaderDeviceMode();
          try {
            await communicator.setReaderDeviceMode(false);
            await communicator.activateSlot(selectedSlot);
            collectionActive = await communicator.isMf1DetectionMode();
          } finally {
            if (originalSlot != selectedSlot) {
              await communicator.activateSlot(originalSlot);
            }
            if (wasReaderMode) {
              await communicator.setReaderDeviceMode(true);
            }
          }
        }
      } else {
        final originalSlot = await communicator.getActiveSlot();
        final wasReaderMode = await communicator.isReaderDeviceMode();
        try {
          await communicator.setReaderDeviceMode(false);

          final candidates = <int>[
            if (originalSlot >= 0 && originalSlot < slots.length) originalSlot,
            for (var index = 0; index < slots.length; index++)
              if (index != originalSlot) index,
          ];

          for (final index in candidates) {
            if (!isMifareClassic(slots[index].hf)) continue;
            await communicator.activateSlot(index);
            if (await communicator.isMf1DetectionMode()) {
              selectedSlot = index;
              compatible = true;
              collectionActive = true;
              break;
            }
          }

          if (selectedSlot == null) {
            await communicator.activateSlot(originalSlot);
            if (wasReaderMode) {
              await communicator.setReaderDeviceMode(true);
            }

            final originalSlotIsClassic = originalSlot >= 0 &&
                originalSlot < slots.length &&
                isMifareClassic(slots[originalSlot].hf);
            final fallbackSlot = originalSlotIsClassic
                ? originalSlot
                : slots.indexWhere((slot) => isMifareClassic(slot.hf));
            if (fallbackSlot >= 0) {
              selectedSlot = fallbackSlot;
              compatible = true;
            }
          }
        } catch (_) {
          try {
            await communicator.activateSlot(originalSlot);
            if (wasReaderMode) {
              await communicator.setReaderDeviceMode(true);
            }
          } catch (_) {
            // Preserve the original inspection error.
          }
          rethrow;
        }
      }

      if (!_isCurrentSession(generation)) return;
      setState(() {
        _detectedSlotIndex = selectedSlot;
        _slotCompatible = compatible;
        _checkingSlot = false;
        _status = compatible
            ? collectionActive
                ? text.slotReady((selectedSlot ?? 7) + 1)
                : text.collectionCanBeRestarted((selectedSlot ?? 7) + 1)
            : widget.slot == null
                ? text.noClassicSlot
                : text.slotIncompatible(_slotNumber);
      });
    } catch (error) {
      if (error is TimeoutException || !_isDeviceConnected) {
        _resetAfterDisconnect();
        return;
      }
      if (!_isCurrentSession(generation)) return;
      setState(() {
        _checkingSlot = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _startAcquisition({bool reset = true}) async {
    if (!_slotCompatible || _collecting || _analyzing) return;
    if (!_isDeviceConnected) {
      _resetAfterDisconnect();
      return;
    }
    final generation = ++_sessionGeneration;

    _pollTimer?.cancel();
    if (reset) {
      _attemptedPairs.clear();
      _results.clear();
      _lastAnalyzedCount = -1;
    }
    _hasStarted = true;

    setState(() {
      _error = null;
      _collecting = true;
      _detectionCount = 0;
      _usableGroups = 0;
      _completedPairs = 0;
      _totalPairs = 0;
      _status = text.preparing;
    });

    try {
      final appState = context.read<ChameleonGUIState>();
      await appState.communicator!.setReaderDeviceMode(false);
      await appState.communicator!.activateSlot(_slotIndex);
      if (_restartFromZeroRequired) {
        await appState.communicator!.setMf1DetectionStatus(false);
        await appState.communicator!.setMf1DetectionStatus(true);
      } else if (!await appState.communicator!.isMf1DetectionMode()) {
        await appState.communicator!.setMf1DetectionStatus(true);
      }

      if (!_isCurrentSession(generation)) return;
      _restartFromZeroRequired = false;
      setState(() {
        _status = text.waitingForReader;
      });

      await _pollDetections(generation: generation);
      if (_isCurrentSession(generation)) _schedulePolling();
    } catch (error) {
      if (error is TimeoutException || !_isDeviceConnected) {
        _resetAfterDisconnect();
        return;
      }
      if (!_isCurrentSession(generation)) return;
      setState(() {
        _collecting = false;
        _error = error.toString();
      });
    }
  }

  void _schedulePolling() {
    if (!mounted || !_collecting || _analyzing || !_isDeviceConnected) return;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollDetections(),
    );
  }

  Future<void> _stopAcquisition() async {
    _pollTimer?.cancel();
    try {
      final appState = context.read<ChameleonGUIState>();
      await appState.communicator!.setMf1DetectionStatus(false);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _collecting = false;
      _status = text.stopped;
    });
  }

  Future<void> _pollDetections({int? generation}) async {
    if (!_isDeviceConnected) {
      _resetAfterDisconnect();
      return;
    }
    if (_polling || !_collecting || _analyzing) return;
    final activeGeneration = generation ?? _sessionGeneration;
    _polling = true;

    try {
      final appState = context.read<ChameleonGUIState>();
      final count = await appState.communicator!.getMf1DetectionCount();
      if (!_isCurrentSession(activeGeneration)) return;

      if (count < 2) {
        setState(() {
          _detectionCount = count;
          _usableGroups = 0;
          _status = count == 0 ? text.waitingForReader : text.oneReading;
        });
        return;
      }

      if (count == _lastAnalyzedCount) {
        setState(() => _detectionCount = count);
        return;
      }

      final detections =
          await appState.communicator!.getMf1DetectionResult(count);
      if (!_isCurrentSession(activeGeneration)) return;
      final groups = _buildGroups(detections);
      final usableGroups =
          groups.where((group) => group.records.length >= 2).toList();

      if (!_isCurrentSession(activeGeneration)) return;
      setState(() {
        _detectionCount = count;
        _usableGroups = usableGroups.length;
      });

      if (usableGroups.isEmpty) {
        setState(() => _status = text.incompatibleReadings);
        _lastAnalyzedCount = count;
        return;
      }

      _pollTimer?.cancel();
      await _analyzeGroups(usableGroups, count, activeGeneration);
    } catch (error) {
      if (error is TimeoutException || !_isDeviceConnected) {
        _resetAfterDisconnect();
        return;
      }
      if (!_isCurrentSession(activeGeneration)) return;
      setState(() {
        _collecting = false;
        _analyzing = false;
        _error = error.toString();
      });
      _pollTimer?.cancel();
    } finally {
      if (activeGeneration == _sessionGeneration) _polling = false;
    }
  }

  List<_Mfkey32Group> _buildGroups(
      Map<int, Map<int, Map<String, List<DetectionResult>>>> detections) {
    final groups = <_Mfkey32Group>[];

    for (final uidEntry in detections.entries) {
      for (final blockEntry in uidEntry.value.entries) {
        for (final keyEntry in blockEntry.value.entries) {
          final uniqueRecords = <String, DetectionResult>{};
          for (final record in keyEntry.value) {
            final signature = '${record.nt}:${record.nr}:${record.ar}';
            uniqueRecords.putIfAbsent(signature, () => record);
          }
          groups.add(_Mfkey32Group(
            uid: uidEntry.key,
            block: blockEntry.key,
            keyType: keyEntry.key,
            records: uniqueRecords.values.toList(growable: false),
          ));
        }
      }
    }

    return groups;
  }

  Future<void> _analyzeGroups(
      List<_Mfkey32Group> groups, int detectionCount, int generation) async {
    final candidates = <_Mfkey32Candidate>[];
    final completedGroups = _results.map((result) => result.groupId).toSet();
    var hasMorePendingCandidates = false;

    candidateSearch:
    for (final group in groups) {
      if (completedGroups.contains(group.id)) continue;
      for (var first = 0; first < group.records.length; first++) {
        for (var second = first + 1; second < group.records.length; second++) {
          final candidate = _Mfkey32Candidate(
            group: group,
            first: group.records[first],
            second: group.records[second],
          );
          if (!_attemptedPairs.contains(candidate.id)) {
            if (candidates.length == _maxPairsPerAnalysisBatch) {
              hasMorePendingCandidates = true;
              break candidateSearch;
            }
            candidates.add(candidate);
          }
        }
      }
    }

    if (candidates.isEmpty) {
      _lastAnalyzedCount = detectionCount;
      if (mounted) {
        setState(() => _status = text.waitingForMoreCompatibleReadings);
        _schedulePolling();
      }
      return;
    }

    setState(() {
      _analyzing = true;
      _completedPairs = 0;
      _totalPairs = candidates.length;
      _status = text.analyzing;
    });

    final groupsWithKeys = <String>{...completedGroups};
    for (final candidate in candidates) {
      if (groupsWithKeys.contains(candidate.group.id)) continue;
      _attemptedPairs.add(candidate.id);

      final recovered = await recovery
          .mfkey32(Mfkey32Dart(
            uid: candidate.group.uid,
            nt0: candidate.first.nt,
            nt1: candidate.second.nt,
            nr0Enc: candidate.first.nr,
            ar0Enc: candidate.first.ar,
            nr1Enc: candidate.second.nr,
            ar1Enc: candidate.second.ar,
          ))
          .timeout(_analysisPairTimeout);
      if (!_isCurrentSession(generation)) return;

      if (recovered.isEmpty) {
        throw StateError(text.invalidRecoveryResult);
      }
      final rawKey = recovered.first;
      final rawBytes = u64ToBytes(rawKey);
      final failed = rawKey == -1 || rawBytes.every((byte) => byte == 0xff);
      if (!failed) {
        final key = Uint8List.fromList(rawBytes.sublist(2, 8));
        final result = _RecoveredMfkey32Key(
          uid: candidate.group.uid,
          block: candidate.group.block,
          keyType: candidate.group.keyType,
          key: key,
        );
        if (!_results.any((existing) => existing.id == result.id)) {
          _results.add(result);
        }
        groupsWithKeys.add(candidate.group.id);
      }

      if (!_isCurrentSession(generation)) return;
      setState(() => _completedPairs++);
    }

    _lastAnalyzedCount =
        hasMorePendingCandidates && _results.isEmpty ? -1 : detectionCount;
    if (!_isCurrentSession(generation)) return;
    if (_results.isNotEmpty) {
      try {
        await _appState!.communicator!.setMf1DetectionStatus(false);
      } catch (_) {}
    }
    if (!_isCurrentSession(generation)) return;
    setState(() {
      _analyzing = false;
      _collecting = _results.isEmpty;
      _status = _results.isEmpty ? text.noKeyYet : text.keysFound;
    });
    if (_collecting) {
      _schedulePolling();
    }
  }

  Future<void> _saveKeys() async {
    if (_results.isEmpty) return;
    final uniqueKeys = <String, Uint8List>{};
    for (final result in _results) {
      uniqueKeys.putIfAbsent(bytesToHex(result.key), () => result.key);
    }

    await showDialog<String>(
      context: context,
      builder: (context) => DictionaryExportMenu(
        defaultName: _results.first.uidText,
        keys: uniqueKeys.values.toList(growable: false),
      ),
    );
  }

  void _updateCardReadProgress() {
    if (!mounted) return;
    setState(() {
      final progress = _activeCardRecovery?.dumpProgress ?? 0;
      _workflowProgress = progress > 0 ? progress : null;
    });
  }

  Future<void> _readOriginalCard() async {
    if (_results.isEmpty || _readingCard || _uploadingCard) return;
    final localizations = AppLocalizations.of(context)!;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.readOriginalCard),
        content: Text(text.presentOriginalCard),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(localizations.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(localizations.read),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    _pollTimer?.cancel();
    setState(() {
      _readingCard = true;
      _error = null;
      _workflowProgress = null;
      _status = text.readingOriginalCard;
    });

    try {
      final appState = context.read<ChameleonGUIState>();
      await appState.communicator!.setMf1DetectionStatus(false);
      if (!mounted) return;
      final info = await readHFInfo(context, _updateCardReadProgress);
      final hfInfo = info.$1;
      final mfcInfo = info.$2;

      if (!hfInfo.cardExist ||
          hfInfo.uid.isEmpty ||
          !isMifareClassic(hfInfo.type) ||
          mfcInfo.recovery == null) {
        throw StateError(text.noClassicCard);
      }

      final cardUid = hfInfo.uid.replaceAll(' ', '').toUpperCase();
      final matchingKeys =
          _results.where((result) => result.uidText == cardUid).toList();
      if (matchingKeys.isEmpty) {
        throw StateError(text.uidMismatch);
      }

      final cardRecovery = mfcInfo.recovery!;
      _activeCardRecovery = cardRecovery;
      final sectorCount =
          mfClassicGetSectorCount(mfcInfo.type, isEV1: mfcInfo.isEV1);
      for (final result in matchingKeys) {
        final sector = mfClassicGetSectorByBlock(result.block);
        if (sector < sectorCount) {
          cardRecovery.setKeyAsFound(
              sector, result.keyType == 'A' ? 0 : 1, result.key);
        }
      }

      final dictionaries = appState.sharedPreferencesProvider
          .getDictionaries(keyLength: 12)
          .where((dictionary) => dictionary.keys.isNotEmpty)
          .toList();
      final selectedId = appState.sharedPreferencesProvider
          .getSelectedMifareClassicDictionaryId();
      cardRecovery.selectedDictionary = dictionaries.isEmpty
          ? Dictionary(id: '', name: localizations.empty, keys: [])
          : dictionaries.firstWhere(
              (dictionary) => dictionary.id == selectedId,
              orElse: () => dictionaries.first,
            );

      setState(() => _status = text.checkingRemainingKeys);
      await cardRecovery.checkKeys();

      if (!mounted) return;
      setState(() => _status = text.readingCardData);
      await cardRecovery.dumpData();

      final totalBlocks =
          mfClassicGetBlockCount(mfcInfo.type, isEV1: mfcInfo.isEV1);
      final readBlocks = cardRecovery.cardDataRead
          .take(totalBlocks)
          .where((read) => read)
          .length;
      final complete = readBlocks == totalBlocks;
      final cards = appState.sharedPreferencesProvider.getCards();
      final baseName = 'MFKEY32_$cardUid';
      var cardName = complete ? baseName : '${baseName}_PARTIAL';
      var suffix = 2;
      while (cards.any((card) => card.name == cardName)) {
        cardName = '${complete ? baseName : '${baseName}_PARTIAL'}_$suffix';
        suffix++;
      }

      final savedCard = CardSave(
        uid: hfInfo.uid,
        sak: hexToBytes(hfInfo.sak)[0],
        atqa: hexToBytes(hfInfo.atqa),
        ats: hfInfo.ats != localizations.no
            ? hexToBytes(hfInfo.ats)
            : Uint8List(0),
        name: cardName,
        tag: mfClassicGetChameleonTagType(mfcInfo.type),
        data: List.generate(
          totalBlocks,
          (index) => Uint8List.fromList(cardRecovery.cardData[index]),
        ),
      );
      cards.add(savedCard);
      appState.sharedPreferencesProvider.setCards(cards);

      if (!mounted) return;
      setState(() {
        _savedCard = savedCard;
        _dumpComplete = complete;
        _readBlocks = readBlocks;
        _totalBlocks = totalBlocks;
        _workflowProgress = 1;
        _readingCard = false;
        _status = complete ? text.completeDumpSaved : text.partialDumpSaved;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _readingCard = false;
        _activeCardRecovery = null;
        _workflowProgress = null;
        _error = error.toString();
        _status = text.cardReadFailed;
      });
    }
  }

  Future<void> _selectSlotAndEmulate() async {
    final card = _savedCard;
    if (card == null || !_dumpComplete || _uploadingCard) return;
    final localizations = AppLocalizations.of(context)!;
    final appState = context.read<ChameleonGUIState>();

    try {
      final enabledSlots = await appState.communicator!.getEnabledSlots();
      var selectedSlot = enabledSlots.indexWhere((slot) => !slot.hf);
      if (selectedSlot < 0) selectedSlot = _slotIndex;
      if (!mounted) return;

      final targetSlot = await showDialog<int>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(text.chooseSlot),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<int>(
                  value: selectedSlot,
                  isExpanded: true,
                  items: List.generate(
                    8,
                    (index) => DropdownMenuItem(
                      value: index,
                      child: Text(
                          '${localizations.slot} ${index + 1}${enabledSlots[index].hf ? ' - ${text.inUse}' : ''}'),
                    ),
                  ),
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedSlot = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                Text(text.slotOverwriteWarning, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(localizations.cancel),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, selectedSlot),
                child: Text(localizations.ok),
              ),
            ],
          ),
        ),
      );
      if (targetSlot == null || !mounted) return;

      setState(() {
        _uploadingCard = true;
        _workflowProgress = 0;
        _error = null;
        _status = text.loadingSlot(targetSlot + 1);
      });

      await loadMifareClassicCardToSlot(
        communicator: appState.communicator!,
        card: card,
        slot: targetSlot,
        fallbackName: localizations.no_name,
        onProgress: (progress) {
          if (mounted) setState(() => _workflowProgress = progress);
        },
      );
      appState.changesMade();

      if (!mounted) return;
      setState(() {
        _uploadingCard = false;
        _emulationSlot = targetSlot;
        _workflowProgress = 1;
        _status = text.emulationReady(targetSlot + 1);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploadingCard = false;
        _workflowProgress = null;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final progress = _totalPairs == 0 ? null : _completedPairs / _totalPairs;

    return Scaffold(
      appBar: AppBar(title: const Text('MFKEY32')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Icon(
                            _slotCompatible
                                ? Icons.lock_open
                                : Icons.warning_amber,
                            size: 48,
                            color: _slotCompatible
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _checkingSlot
                                ? text.checkingSlot(_slotNumber)
                                : _status,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            text.authorizedUse,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_checkingSlot) ...[
                            const SizedBox(height: 16),
                            const CircularProgressIndicator(),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_checkingSlot && _slotCompatible) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(text.readerInstructions,
                                textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 24,
                              runSpacing: 8,
                              children: [
                                _Counter(
                                    label: text.readings,
                                    value: _detectionCount),
                                _Counter(
                                    label: text.compatibleGroups,
                                    value: _usableGroups),
                                _Counter(
                                    label: localizations.found_keys,
                                    value: _results.length),
                              ],
                            ),
                            if (_analyzing) ...[
                              const SizedBox(height: 16),
                              LinearProgressIndicator(value: progress),
                            ],
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (!_collecting &&
                                    !_analyzing &&
                                    !_readingCard &&
                                    !_uploadingCard)
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        _startAcquisition(reset: !_hasStarted),
                                    icon: const Icon(Icons.play_arrow),
                                    label: Text(!_hasStarted
                                        ? text.start
                                        : text.continueAcquisition),
                                  ),
                                if (_collecting && !_analyzing)
                                  OutlinedButton.icon(
                                    onPressed: _stopAcquisition,
                                    icon: const Icon(Icons.stop),
                                    label: Text(text.stop),
                                  ),
                                if (_results.isNotEmpty)
                                  ElevatedButton.icon(
                                    onPressed: (_readingCard || _uploadingCard)
                                        ? null
                                        : _saveKeys,
                                    icon: const Icon(Icons.save),
                                    label:
                                        Text(localizations.save_recovered_keys),
                                  ),
                                if (_results.isNotEmpty && _savedCard == null)
                                  ElevatedButton.icon(
                                    onPressed: (_readingCard || _uploadingCard)
                                        ? null
                                        : _readOriginalCard,
                                    icon: const Icon(Icons.credit_card),
                                    label: Text(text.readOriginalCard),
                                  ),
                              ],
                            ),
                            if (_readingCard || _uploadingCard) ...[
                              const SizedBox(height: 16),
                              LinearProgressIndicator(value: _workflowProgress),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (!_checkingSlot && !_slotCompatible) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _inspectSlot,
                      icon: const Icon(Icons.refresh),
                      label: Text(text.checkAgain),
                    ),
                  ],
                  if (_results.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(localizations.found_keys,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    ..._results.map((result) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.key),
                            title: Text(result.keyText,
                                style: const TextStyle(
                                    fontFamily: 'RobotoMono',
                                    fontWeight: FontWeight.bold)),
                            subtitle: Text(
                              'UID ${result.uidText} · '
                              '${localizations.block} ${result.block} · '
                              '${localizations.sector} ${mfClassicGetSectorByBlock(result.block)} · '
                              'Key ${result.keyType}',
                            ),
                            trailing: IconButton(
                              onPressed: () => Clipboard.setData(
                                  ClipboardData(text: result.keyText)),
                              icon: const Icon(Icons.copy),
                              tooltip: localizations.copy_all_keys,
                            ),
                          ),
                        )),
                  ],
                  if (_savedCard != null) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Icon(
                              _dumpComplete
                                  ? Icons.check_circle
                                  : Icons.warning_amber,
                              size: 44,
                              color: _dumpComplete
                                  ? Colors.green
                                  : Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _dumpComplete
                                  ? text.completeDumpSaved
                                  : text.partialDumpSaved,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text('${localizations.name}: ${_savedCard!.name}'),
                            Text(
                                '${text.blocksRead}: $_readBlocks/$_totalBlocks'),
                            const SizedBox(height: 12),
                            if (_dumpComplete && _emulationSlot == null)
                              ElevatedButton.icon(
                                onPressed: _uploadingCard
                                    ? null
                                    : _selectSlotAndEmulate,
                                icon: const Icon(Icons.upload),
                                label: Text(text.loadIntoSlot),
                              ),
                            if (!_dumpComplete)
                              Text(text.partialNotLoaded,
                                  textAlign: TextAlign.center),
                            if (_emulationSlot != null)
                              Text(
                                text.emulationReady(_emulationSlot! + 1),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  final String label;
  final int value;

  const _Counter({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$value', style: Theme.of(context).textTheme.headlineSmall),
        Text(label),
      ],
    );
  }
}

class _Mfkey32Group {
  final int uid;
  final int block;
  final String keyType;
  final List<DetectionResult> records;

  const _Mfkey32Group({
    required this.uid,
    required this.block,
    required this.keyType,
    required this.records,
  });

  String get id => '$uid:$block:$keyType';
}

class _Mfkey32Candidate {
  final _Mfkey32Group group;
  final DetectionResult first;
  final DetectionResult second;

  const _Mfkey32Candidate({
    required this.group,
    required this.first,
    required this.second,
  });

  String get id {
    final firstId = '${first.nt}:${first.nr}:${first.ar}';
    final secondId = '${second.nt}:${second.nr}:${second.ar}';
    final ordered = [firstId, secondId]..sort();
    return '${group.id}:${ordered[0]}:${ordered[1]}';
  }
}

class _RecoveredMfkey32Key {
  final int uid;
  final int block;
  final String keyType;
  final Uint8List key;

  const _RecoveredMfkey32Key({
    required this.uid,
    required this.block,
    required this.keyType,
    required this.key,
  });

  String get uidText => bytesToHex(u64ToBytes(uid).sublist(4, 8)).toUpperCase();
  String get keyText => bytesToHex(key).toUpperCase();
  String get groupId => '$uid:$block:$keyType';
  String get id => '$groupId:$keyText';
}

class Mfkey32Text {
  final bool italian;

  const Mfkey32Text(this.italian);

  String get searchingActiveCollection => italian
      ? 'Ricerca dello slot con raccolta nonce attiva…'
      : 'Searching for a slot with active nonce collection…';
  String get noClassicSlot => italian
      ? 'Nessuno slot è configurato come MIFARE Classic.'
      : 'No slot is configured as MIFARE Classic.';
  String checkingSlot(int slot) =>
      italian ? 'Controllo dello slot $slot…' : 'Checking slot $slot…';
  String slotReady(int slot) => italian
      ? 'Slot $slot pronto per MFKEY32'
      : 'Slot $slot is ready for MFKEY32';
  String collectionCanBeRestarted(int slot) => italian
      ? 'La raccolta nonce non è attiva. Premi Avvia per riattivarla nello slot $slot.'
      : 'Nonce collection is not active. Press Start to enable it again in slot $slot.';
  String slotIncompatible(int slot) => italian
      ? 'Lo slot $slot deve essere configurato come MIFARE Classic.'
      : 'Slot $slot must be configured as MIFARE Classic.';
  String get authorizedUse => italian
      ? 'Usa questa funzione esclusivamente su sistemi per i quali sei autorizzato.'
      : 'Use this feature only on systems you are authorized to test.';
  String get readerInstructions => italian
      ? 'Premi Avvia, poi avvicina il Chameleon al lettore 2–4 volte. L’analisi partirà automaticamente quando i dati saranno sufficienti.'
      : 'Press Start, then present Chameleon to the reader 2–4 times. Analysis starts automatically when enough data is available.';
  String get preparing =>
      italian ? 'Preparazione dell’acquisizione…' : 'Preparing acquisition…';
  String get waitingForReader => italian
      ? 'In attesa della prima lettura…'
      : 'Waiting for the first read…';
  String get oneReading => italian
      ? 'Prima lettura ricevuta: esegui un’altra lettura.'
      : 'First read received: perform another read.';
  String get incompatibleReadings => italian
      ? 'Letture ricevute, ma non ancora compatibili. Ripeti la lettura.'
      : 'Reads received, but not compatible yet. Try again.';
  String get waitingForMoreCompatibleReadings => italian
      ? 'Servono altre letture compatibili.'
      : 'More compatible reads are required.';
  String get analyzing => italian
      ? 'Analisi automatica in corso…'
      : 'Automatic analysis in progress…';
  String get invalidRecoveryResult => italian
      ? 'MFKEY32 non ha restituito un risultato valido.'
      : 'MFKEY32 did not return a valid result.';
  String get noKeyYet => italian
      ? 'Nessuna chiave trovata: acquisisci altre letture.'
      : 'No key found: collect more reads.';
  String get keysFound => italian ? 'Chiave trovata.' : 'Key found.';
  String get stopped =>
      italian ? 'Acquisizione interrotta.' : 'Acquisition stopped.';
  String get deviceDisconnected => italian
      ? 'Chameleon disconnesso. Ricollegalo, premi Controlla di nuovo e riavvia MFKEY32.'
      : 'Chameleon disconnected. Reconnect it, press Check again, and restart MFKEY32.';
  String get start =>
      italian ? 'Avvia acquisizione MFKEY32' : 'Start MFKEY32 acquisition';
  String get stop => italian ? 'Interrompi' : 'Stop';
  String get continueAcquisition =>
      italian ? 'Analizza altre letture' : 'Analyze more reads';
  String get checkAgain => italian ? 'Controlla di nuovo' : 'Check again';
  String get readings => italian ? 'Letture ricevute' : 'Reads received';
  String get compatibleGroups =>
      italian ? 'Gruppi compatibili' : 'Compatible groups';
  String get readOriginalCard =>
      italian ? 'Leggi carta originale' : 'Read original card';
  String get presentOriginalCard => italian
      ? 'Disattiva il lettore esterno, avvicina la carta originale al Chameleon e premi Leggi.'
      : 'Turn off the external reader, place the original card near Chameleon, then press Read.';
  String get readingOriginalCard => italian
      ? 'Rilevamento della carta originale…'
      : 'Detecting the original card…';
  String get noClassicCard => italian
      ? 'Non è stata rilevata una carta MIFARE Classic.'
      : 'No MIFARE Classic card was detected.';
  String get uidMismatch => italian
      ? 'L’UID della carta non corrisponde alle acquisizioni MFKEY32.'
      : 'The card UID does not match the MFKEY32 acquisition.';
  String get checkingRemainingKeys => italian
      ? 'Controllo automatico delle chiavi mancanti…'
      : 'Automatically checking missing keys…';
  String get readingCardData =>
      italian ? 'Lettura del dump della carta…' : 'Reading card dump…';
  String get cardReadFailed =>
      italian ? 'Lettura della carta non riuscita.' : 'Card read failed.';
  String get completeDumpSaved => italian
      ? 'Dump completo salvato in Carte salvate.'
      : 'Complete dump saved to Saved cards.';
  String get partialDumpSaved => italian
      ? 'Dump parziale salvato in Carte salvate.'
      : 'Partial dump saved to Saved cards.';
  String get blocksRead => italian ? 'Blocchi letti' : 'Blocks read';
  String get loadIntoSlot =>
      italian ? 'Carica in uno slot' : 'Load into a slot';
  String get chooseSlot =>
      italian ? 'Scegli lo slot di emulazione' : 'Choose emulation slot';
  String get inUse => italian ? 'in uso' : 'in use';
  String get slotOverwriteWarning => italian
      ? 'Il contenuto HF dello slot selezionato verrà sostituito. Il dump è già al sicuro in Carte salvate.'
      : 'The selected slot HF content will be replaced. The dump is already saved in Saved cards.';
  String get partialNotLoaded => italian
      ? 'Per sicurezza, un dump parziale non viene caricato automaticamente in emulazione.'
      : 'For safety, a partial dump is not loaded into emulation automatically.';
  String loadingSlot(int slot) => italian
      ? 'Caricamento del dump nello slot $slot…'
      : 'Loading dump into slot $slot…';
  String emulationReady(int slot) => italian
      ? 'Emulazione pronta nello slot $slot.'
      : 'Emulation ready in slot $slot.';
}
