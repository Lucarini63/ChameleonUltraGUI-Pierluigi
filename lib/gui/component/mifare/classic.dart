import 'dart:io';
import 'dart:typed_data';

import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/gui/component/key_check_marks.dart';
import 'package:chameleonultragui/gui/menu/dialogs/dictionary/export.dart';
import 'package:chameleonultragui/gui/menu/pages/dump_editor.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class MifareClassicHelper extends StatefulWidget {
  final HFCardInfo hfInfo;
  final MifareClassicInfo mfcInfo;
  final bool allowSave;
  final bool onlySelectedDictionary;
  final bool autoRecoverMissingKeys;

  const MifareClassicHelper(
      {super.key,
      required this.hfInfo,
      required this.mfcInfo,
      this.allowSave = true,
      this.onlySelectedDictionary = false,
      this.autoRecoverMissingKeys = false});

  @override
  State<StatefulWidget> createState() => CardReaderState();
}

class CardReaderState extends State<MifareClassicHelper> {
  String dumpName = "";
  bool skipDefaultDictionary = false;

  String _attackMethodName(MifareClassicAttackMethod method) {
    switch (method) {
      case MifareClassicAttackMethod.darkside:
        return 'Darkside';
      case MifareClassicAttackMethod.nested:
        return 'Nested';
      case MifareClassicAttackMethod.staticNested:
        return 'Static Nested';
      case MifareClassicAttackMethod.hardNested:
        return 'Hardnested';
      case MifareClassicAttackMethod.backdoor:
        return 'Backdoor';
    }
  }

  String _ntLevelName(NTLevel level) {
    switch (level) {
      case NTLevel.static:
        return 'Static';
      case NTLevel.weak:
        return 'Weak';
      case NTLevel.hard:
        return 'Hard';
      case NTLevel.backdoor:
        return 'Backdoor';
      case NTLevel.unknown:
        return 'Unknown';
    }
  }

  Future<void> _checkKeys(MifareClassicRecovery recovery) async {
    if (widget.mfcInfo.state != MifareClassicState.checkKeys) return;
    recovery.resetCancellation();

    setState(() {
      recovery.attackPlan = null;
      widget.mfcInfo.state = MifareClassicState.checkKeysOngoing;
    });

    try {
      await recovery.checkKeys(
          skipDefaultDictionary:
              widget.onlySelectedDictionary || skipDefaultDictionary);
      if (!mounted || widget.mfcInfo.recovery != recovery) return;

      if (recovery.allKeysExists) {
        setState(() {
          widget.mfcInfo.state = MifareClassicState.dump;
        });
      } else if (widget.autoRecoverMissingKeys) {
        await _recoverMissingKeys(recovery, resetCancellation: false);
      } else {
        setState(() {
          widget.mfcInfo.state = MifareClassicState.recovery;
        });
      }
    } on MifareClassicRecoveryCancelled {
      for (var checkmark = 0; checkmark < 80; checkmark++) {
        if (recovery.checkMarks[checkmark] == ChameleonKeyCheckmark.checking) {
          recovery.checkMarks[checkmark] = ChameleonKeyCheckmark.none;
        }
      }
      if (!mounted || widget.mfcInfo.recovery != recovery) return;
      setState(() {
        recovery.keyCheckProgress = null;
        recovery.state = '';
        widget.mfcInfo.state = MifareClassicState.checkKeys;
      });
    } catch (_) {
      for (var checkmark = 0; checkmark < 80; checkmark++) {
        if (recovery.checkMarks[checkmark] == ChameleonKeyCheckmark.checking) {
          recovery.checkMarks[checkmark] = ChameleonKeyCheckmark.none;
        }
      }

      if (!mounted || widget.mfcInfo.recovery != recovery) return;
      setState(() {
        recovery.checkMarks = recovery.checkMarks;
        recovery.error = AppLocalizations.of(context)!.recovery_error_dict;
        widget.mfcInfo.state = MifareClassicState.checkKeys;
      });
    }
  }

  Future<void> _recoverMissingKeys(MifareClassicRecovery recovery,
      {bool resetCancellation = true}) async {
    if (!mounted || widget.mfcInfo.recovery != recovery) return;
    if (resetCancellation) {
      recovery.resetCancellation();
    }

    setState(() {
      widget.mfcInfo.state = MifareClassicState.recoveryOngoing;
    });

    try {
      await recovery.recoverKeys();
    } on MifareClassicRecoveryCancelled {
      for (var checkmark = 0; checkmark < 80; checkmark++) {
        if (recovery.checkMarks[checkmark] == ChameleonKeyCheckmark.checking) {
          recovery.checkMarks[checkmark] = ChameleonKeyCheckmark.none;
        }
      }

      if (!mounted || widget.mfcInfo.recovery != recovery) return;
      setState(() {
        recovery.hardnestedProgress = null;
        recovery.recoveryProgress = null;
        recovery.attackPlan?.currentStep = null;
        recovery.state = '';
        widget.mfcInfo.state = MifareClassicState.recovery;
      });
      return;
    } catch (_) {
      if (!mounted || widget.mfcInfo.recovery != recovery) return;
      recovery.recoveryProgress = null;
      recovery.attackPlan?.currentStep = null;
      if (recovery.error.isEmpty) {
        recovery.error =
            AppLocalizations.of(context)!.recovery_error_no_supported;
      }
    }

    if (!mounted || widget.mfcInfo.recovery != recovery) return;
    setState(() {
      widget.mfcInfo.state = recovery.error.isEmpty && recovery.allKeysExists
          ? MifareClassicState.dump
          : MifareClassicState.recovery;
    });
  }

  Future<void> exportFoundKeys() async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return DictionaryExportMenu(keys: widget.mfcInfo.recovery!.validKeys);
      },
    );
  }

  Future<void> saveCard({bool bin = false, bool skipDump = false}) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    List<int> cardDump = [];
    var localizations = AppLocalizations.of(context)!;
    if (!skipDump) {
      for (var sector = 0;
          sector < mfClassicGetSectorCount(widget.mfcInfo.type);
          sector++) {
        for (var block = 0;
            block < mfClassicGetBlockCountBySector(sector);
            block++) {
          cardDump.addAll(widget.mfcInfo.recovery!
              .cardData[block + mfClassicGetFirstBlockCountBySector(sector)]);
        }
      }
    }

    if (bin) {
      try {
        await FileSaver.instance.saveAs(
            name: widget.hfInfo.uid.replaceAll(" ", ""),
            bytes: Uint8List.fromList(cardDump),
            ext: 'bin',
            mimeType: MimeType.other);
      } on UnimplementedError catch (_) {
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: '${localizations.output_file}:',
          fileName: '${widget.hfInfo.uid.replaceAll(" ", "")}.bin',
        );

        if (outputFile != null) {
          var file = File(outputFile);
          await file.writeAsBytes(Uint8List.fromList(cardDump));
        }
      }
    } else {
      var tags = appState.sharedPreferencesProvider.getCards();
      tags.add(CardSave(
          uid: widget.hfInfo.uid,
          sak: hexToBytes(widget.hfInfo.sak)[0],
          atqa: hexToBytes(widget.hfInfo.atqa),
          name: dumpName,
          tag: (skipDump)
              ? TagType.mifare1K
              : mfClassicGetChameleonTagType(widget.mfcInfo.type),
          data: widget.mfcInfo.recovery!.cardData,
          ats: (widget.hfInfo.ats != localizations.no)
              ? hexToBytes(widget.hfInfo.ats)
              : Uint8List(0)));
      appState.sharedPreferencesProvider.setCards(tags);
    }
  }

  Future<void> openDumpEditor() async {
    final recovery = widget.mfcInfo.recovery;
    if (recovery == null) return;

    final localizations = AppLocalizations.of(context)!;
    final card = CardSave(
      uid: widget.hfInfo.uid,
      sak: hexToBytes(widget.hfInfo.sak)[0],
      atqa: hexToBytes(widget.hfInfo.atqa),
      ats: widget.hfInfo.ats != localizations.no
          ? hexToBytes(widget.hfInfo.ats)
          : Uint8List(0),
      name: dumpName,
      tag: mfClassicGetChameleonTagType(widget.mfcInfo.type),
      data: recovery.cardData,
    );

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DumpEditor(
          cardSave: card,
          onSave: (dumpData) {
            recovery.cardData = dumpData;
            recovery.update();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    var localizations = AppLocalizations.of(context)!;
    final isSmallScreen = screenSize.width < 800;

    double checkmarkFontSize = isSmallScreen ? 12 : 16;
    double checkmarkSize = isSmallScreen ? 16 : 20;
    int checkmarkPerRow = (screenSize.width < 600) ? 8 : 16;

    var appState = context.watch<ChameleonGUIState>();
    final dictionaries =
        appState.sharedPreferencesProvider.getDictionaries(keyLength: 12);
    widget.mfcInfo.recovery?.dictionaries = dictionaries;
    widget.mfcInfo.recovery?.dictionaries
        .insert(0, Dictionary(id: "", name: localizations.empty, keys: []));
    if (widget.mfcInfo.recovery?.selectedDictionary == null) {
      final selectedId = appState.sharedPreferencesProvider
          .getSelectedMifareClassicDictionaryId();
      widget.mfcInfo.recovery?.selectedDictionary =
          widget.mfcInfo.recovery?.dictionaries.firstWhere(
        (dictionary) => dictionary.id == selectedId,
        orElse: () => widget.mfcInfo.recovery!.dictionaries.length > 1
            ? widget.mfcInfo.recovery!.dictionaries[1]
            : widget.mfcInfo.recovery!.dictionaries[0],
      );
    }

    WakelockPlus.toggle(
        enable: [
      MifareClassicState.checkKeysOngoing,
      MifareClassicState.recoveryOngoing,
      MifareClassicState.dumpOngoing
    ].contains(widget.mfcInfo.state));

    return Column(children: [
      const SizedBox(height: 16),
      Text(
        localizations.keys,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
        ),
      ),
      if (widget.mfcInfo.recovery != null) ...[
        Row(
          children: [
            const Spacer(),
            KeyCheckMarks(
                checkMarks: widget.mfcInfo.recovery!.checkMarks,
                validKeys: widget.mfcInfo.recovery!.validKeys,
                fontSize: checkmarkFontSize,
                checkmarkSize: checkmarkSize,
                checkmarkCount: mfClassicGetSectorCount(widget.mfcInfo.type,
                    isEV1: widget.mfcInfo.isEV1),
                checkmarkPerRow: checkmarkPerRow,
                onCheckmarkChanged: (index, newValue) {
                  widget.mfcInfo.recovery!.checkMarks[index] = newValue;
                  widget.mfcInfo.recovery!.update();
                }),
            const Spacer(),
          ],
        ),
        if (widget.mfcInfo.recovery?.error != "") ...[
          const SizedBox(height: 16),
          ErrorMessage(errorMessage: widget.mfcInfo.recovery!.error),
        ],
        if (widget.mfcInfo.recovery?.state != "") ...[
          const SizedBox(height: 8),
          Text(widget.mfcInfo.recovery!.state),
        ],
        if (widget.mfcInfo.recovery?.attackPlan case final plan?) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    localizations.checking_card_info,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text('${localizations.prng_type}: '
                      '${_ntLevelName(plan.prng)} • '
                      '${localizations.has_backdoor_support}: '
                      '${plan.hasBackdoor ? localizations.yes : localizations.no}'),
                  Text('${localizations.found_keys}: ${plan.foundKeys} • '
                      '${localizations.no_key}: ${plan.missingKeys}'),
                  Text(
                    plan.steps.isEmpty
                        ? localizations.recovery_error_no_keys_darkside
                        : localizations.recover_keys_via(
                            plan.steps.map(_attackMethodName).join(' → ')),
                  ),
                  if (plan.currentStep != null)
                    Text(
                      localizations.recover_keys_via(
                        _attackMethodName(plan.currentStep!),
                      ),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (widget.mfcInfo.recovery?.dumpProgress != 0) ...[
          LinearProgressIndicator(value: widget.mfcInfo.recovery?.dumpProgress),
          const SizedBox(height: 8)
        ],
        if (widget.mfcInfo.recovery?.hardnestedProgress != null &&
            widget.mfcInfo.recovery?.error == "") ...[
          LinearProgressIndicator(
              value: widget.mfcInfo.recovery?.hardnestedProgress),
          const SizedBox(height: 12)
        ],
        if (widget.mfcInfo.recovery?.keyCheckProgress != null) ...[
          LinearProgressIndicator(
              value: widget.mfcInfo.recovery?.keyCheckProgress),
          const SizedBox(height: 12)
        ],
        if (widget.mfcInfo.recovery?.recoveryProgress != null) ...[
          LinearProgressIndicator(
              value: widget.mfcInfo.recovery?.recoveryProgress),
          const SizedBox(height: 12)
        ],
        if (widget.mfcInfo.state == MifareClassicState.checkKeysOngoing ||
            widget.mfcInfo.state == MifareClassicState.recoveryOngoing) ...[
          ElevatedButton.icon(
            onPressed: widget.mfcInfo.recovery!.cancellationRequested
                ? null
                : widget.mfcInfo.recovery!.requestCancellation,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(localizations.cancel),
          ),
          const SizedBox(height: 12),
        ],
        if (widget.mfcInfo.state == MifareClassicState.recovery ||
            widget.mfcInfo.state == MifareClassicState.recoveryOngoing)
          FittedBox(
              alignment: Alignment.topCenter,
              fit: BoxFit.scaleDown,
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: (widget.mfcInfo.state ==
                              MifareClassicState.recovery)
                          ? () => _recoverMissingKeys(widget.mfcInfo.recovery!)
                          : null,
                      style: customCardButtonStyle(appState),
                      child: Text(localizations.recover_keys),
                    ),
                    if (widget.allowSave) ...[
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: (widget.mfcInfo.state ==
                                MifareClassicState.recovery)
                            ? () async {
                                setState(() {
                                  widget.mfcInfo.state =
                                      MifareClassicState.dumpOngoing;
                                });

                                try {
                                  await widget.mfcInfo.recovery?.dumpData();

                                  setState(() {
                                    widget.mfcInfo.recovery?.dumpProgress = 0;
                                    widget.mfcInfo.state =
                                        MifareClassicState.save;
                                  });
                                } catch (_) {
                                  setState(() {
                                    widget.mfcInfo.recovery?.error =
                                        localizations.recovery_error_dump_data;
                                    widget.mfcInfo.state =
                                        MifareClassicState.dump;
                                  });
                                }
                              }
                            : null,
                        style: customCardButtonStyle(appState),
                        child: Text(localizations.dump_partial_data),
                      )
                    ],
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () async {
                        await exportFoundKeys();
                      },
                      style: customCardButtonStyle(appState),
                      child: Text(localizations.export_to_dictionary),
                    ),
                  ])),
        if (widget.mfcInfo.state == MifareClassicState.checkKeys ||
            widget.mfcInfo.state == MifareClassicState.checkKeysOngoing)
          Column(children: [
            if (widget.mfcInfo.state == MifareClassicState.checkKeys)
              Column(children: [
                if (!widget.onlySelectedDictionary) ...[
                  Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                          width: 275, // WIP: center without this
                          child: CheckboxListTile(
                            title: Text(localizations.skip_default_dictionary),
                            value: skipDefaultDictionary,
                            onChanged: (bool? newValue) {
                              setState(() {
                                skipDefaultDictionary = newValue!;
                              });
                            },
                            controlAffinity: ListTileControlAffinity.leading,
                          ))),
                  const SizedBox(height: 8),
                ],
                Text(widget.onlySelectedDictionary
                    ? localizations.dictionary
                    : localizations.additional_key_dict),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  value: widget.mfcInfo.recovery?.selectedDictionary!.id,
                  items: widget.mfcInfo.recovery?.dictionaries
                      .map<DropdownMenuItem<String>>((Dictionary dictionary) {
                    return DropdownMenuItem<String>(
                      value: dictionary.id,
                      child: Text(
                          "${dictionary.name} (${dictionary.keys.length} ${localizations.keys.toLowerCase()})"),
                    );
                  }).toList(),
                  onChanged: (String? newValue) {
                    for (var dictionary
                        in widget.mfcInfo.recovery!.dictionaries) {
                      if (dictionary.id == newValue) {
                        setState(() {
                          widget.mfcInfo.recovery?.selectedDictionary =
                              dictionary;
                          appState.sharedPreferencesProvider
                              .setSelectedMifareClassicDictionaryId(
                                  dictionary.id);
                        });
                        break;
                      }
                    }
                  },
                ),
                const SizedBox(height: 8),
              ]),
            ElevatedButton(
              onPressed:
                  (widget.mfcInfo.state == MifareClassicState.checkKeys &&
                          (!widget.onlySelectedDictionary ||
                              (widget.mfcInfo.recovery?.selectedDictionary?.id
                                      .isNotEmpty ??
                                  false)))
                      ? () => _checkKeys(widget.mfcInfo.recovery!)
                      : null,
              style: customCardButtonStyle(appState),
              child: Text(localizations.check_keys_dict),
            )
          ]),
        if ((widget.mfcInfo.state == MifareClassicState.dump ||
                widget.mfcInfo.state == MifareClassicState.dumpOngoing) &&
            widget.allowSave)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: (widget.mfcInfo.state == MifareClassicState.dump)
                      ? () async {
                          setState(() {
                            widget.mfcInfo.state =
                                MifareClassicState.dumpOngoing;
                          });

                          try {
                            await widget.mfcInfo.recovery?.dumpData();

                            setState(() {
                              widget.mfcInfo.recovery?.dumpProgress = 0;
                              widget.mfcInfo.state = MifareClassicState.save;
                            });
                          } catch (_) {
                            setState(() {
                              widget.mfcInfo.recovery?.error =
                                  localizations.recovery_error_dump_data;
                              widget.mfcInfo.state = MifareClassicState.dump;
                            });
                          }
                        }
                      : null,
                  style: customCardButtonStyle(appState),
                  child: Text(
                    localizations.dump_card,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await exportFoundKeys();
                  },
                  style: customCardButtonStyle(appState),
                  child: Text(
                    localizations.export_to_dictionary,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
      if (widget.mfcInfo.state == MifareClassicState.save && widget.allowSave)
        Center(
            child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
              ElevatedButton(
                onPressed: openDumpEditor,
                style: customCardButtonStyle(appState),
                child: Text("${localizations.read} ${localizations.dump}"),
              ),
              ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: Text(localizations.enter_name_of_card),
                        content: TextField(
                          onChanged: (value) {
                            setState(() {
                              dumpName = value;
                            });
                          },
                        ),
                        actions: [
                          ElevatedButton(
                            onPressed: () async {
                              await saveCard();
                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                            child: Text(localizations.ok),
                          ),
                          ElevatedButton(
                            onPressed: () {
                              Navigator.pop(
                                  context); // Close the modal without saving
                            },
                            child: Text(localizations.cancel),
                          ),
                        ],
                      );
                    },
                  );
                },
                style: customCardButtonStyle(appState),
                child: Text(localizations.save),
              ),
              ElevatedButton(
                onPressed: () async {
                  await saveCard(bin: true);
                },
                style: customCardButtonStyle(appState),
                child: Text(localizations.save_as(".bin")),
              ),
            ])),
    ]);
  }
}
