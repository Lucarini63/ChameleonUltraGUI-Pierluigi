import 'dart:math';
import 'dart:typed_data';

import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/write/verification.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/write/base.dart';
import 'package:chameleonultragui/helpers/write.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class WriteCardPage extends StatefulWidget {
  const WriteCardPage({super.key});

  @override
  WriteCardPageState createState() => WriteCardPageState();
}

class WriteCardPageState extends State<WriteCardPage> {
  int step = 0;
  int progress = -1;
  bool written = false;
  CardSave? card;
  AbstractWriteHelper? baseHelper;
  AbstractWriteHelper? helper;
  bool randomizeUid = false;
  Uint8List? randomUid;
  bool verifyingClone = false;

  _RandomUidText get _randomUidText => _RandomUidText(
      Localizations.localeOf(context).languageCode.toLowerCase() == 'it');

  bool get canRandomizeUid {
    if (card == null || !isMifareClassic(card!.tag)) return false;
    final uid = hexToBytes(card!.uid);
    return uid.length == 4 &&
        card!.data.isNotEmpty &&
        card!.data.first.length >= 16;
  }

  Uint8List generateRandomUid() {
    final secureRandom = Random.secure();
    final originalUid = card == null ? '' : bytesToHex(hexToBytes(card!.uid));
    Uint8List generated;

    do {
      generated = Uint8List.fromList([
        0x08,
        secureRandom.nextInt(256),
        secureRandom.nextInt(256),
        secureRandom.nextInt(256),
      ]);
    } while (bytesToHex(generated) == originalUid);

    return generated;
  }

  CardSave getCardForWrite() {
    if (!randomizeUid || randomUid == null || !canRandomizeUid) {
      return card!;
    }

    final copiedData = card!.data
        .map((block) => Uint8List.fromList(block))
        .toList(growable: true);
    final uid = Uint8List.fromList(randomUid!);
    copiedData[0].setRange(0, uid.length, uid);
    copiedData[0][4] = uid.fold(0, (bcc, byte) => bcc ^ byte);

    return CardSave(
      uid: bytesToHexSpace(uid),
      name: card!.name,
      tag: card!.tag,
      sak: card!.sak,
      atqa: Uint8List.fromList(card!.atqa),
      ats: Uint8List.fromList(card!.ats),
      extraData: card!.extraData,
      color: card!.color,
      data: copiedData,
    );
  }

  Future<String?> cardSelectDialog(BuildContext context) {
    var appState = context.read<ChameleonGUIState>();
    var tags = appState.sharedPreferencesProvider.getCards();

    tags.sort((a, b) => a.name.compareTo(b.name));

    return showSearch<String>(
      context: context,
      delegate: CardSearchDelegate(cards: tags, onTap: onTap),
    );
  }

  Future<void> onTap(CardSave selectedCard, dynamic close,
      AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    setState(() {
      card = selectedCard;
      randomizeUid = false;
      randomUid = null;
      baseHelper = AbstractWriteHelper.getClassByCardType(
          selectedCard.tag, appState, updateState, localizations);
    });

    if (baseHelper != null) {
      setState(() {
        helper = baseHelper!.getAvailableMethods()[0];
        if (helper is BaseMifareUltralightWriteHelper &&
            selectedCard.extraData.ultralightPassword.length == 4) {
          (helper as BaseMifareUltralightWriteHelper)
              .useSavedPassword(selectedCard.extraData.ultralightPassword);
        }
      });
    }

    await helper?.getCardType();

    if (!mounted) return;
    close(context, selectedCard.name);
  }

  Future<void> detectMagicType() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    var localizations = AppLocalizations.of(context)!;

    if (!await appState.communicator!.isReaderDeviceMode()) {
      await appState.communicator!.setReaderDeviceMode(true);
    }

    for (final magicHelper in baseHelper!.getAvailableMethods()) {
      if (await magicHelper.isMagic(card)) {
        setState(() {
          helper = magicHelper;
        });

        try {
          await helper?.getCardType();
        } catch (_) {
          await helper?.getCardType();
        }

        appState.log!.i("Detected Magic card type: ${magicHelper.name}");
        scaffoldMessenger.hideCurrentSnackBar();
        var snackBar = SnackBar(
          content: Text(
              '${localizations.detected_magic_card_type}: ${helper!.name}'),
          action: SnackBarAction(
            label: localizations.close,
            onPressed: () {},
          ),
        );

        scaffoldMessenger.showSnackBar(snackBar);
        return;
      }
    }

    var snackBar = SnackBar(
      content: Text(localizations.failed_to_detect_magic_card_type),
      action: SnackBarAction(
        label: localizations.close,
        onPressed: () {},
      ),
    );

    scaffoldMessenger.showSnackBar(snackBar);
  }

  void updateState() {
    setState(() {
      helper = helper;
    });
  }

  void updateProgress(int writeProgress) {
    setState(() {
      progress = writeProgress;
    });
  }

  Future<void> writeCard() async {
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    var localizations = AppLocalizations.of(context)!;
    var appState = context.read<ChameleonGUIState>();
    updateProgress(0);

    final cardToWrite = getCardForWrite();
    var writeSuccessful = await helper!.writeData(cardToWrite, updateProgress);
    MifareClassicCloneVerification? verification;

    if (isMifareClassic(cardToWrite.tag)) {
      if (mounted) {
        setState(() {
          verifyingClone = true;
          progress = 0;
        });
      }
      try {
        await Future.delayed(const Duration(milliseconds: 150));
        verification = await verifyMifareClassicClone(
          communicator: appState.communicator!,
          expected: cardToWrite,
          onProgress: (checked, total) {
            if (mounted && total > 0) {
              updateProgress((checked / total * 100).round());
            }
          },
        );
        writeSuccessful = verification.isIdentical;
      } catch (_) {
        writeSuccessful = false;
      } finally {
        if (mounted) {
          setState(() {
            verifyingClone = false;
          });
        }
      }
    }

    if (!mounted) return;

    if (verification != null) {
      await _showCloneVerification(
        verification,
        uidChanged: randomizeUid && randomUid != null,
      );
    } else {
      final snackBar = SnackBar(
        content: Text(writeSuccessful
            ? localizations.magic_success_write
            : localizations.magic_failed_write),
        action: SnackBarAction(
          label: localizations.close,
          onPressed: () {},
        ),
      );
      scaffoldMessenger.hideCurrentSnackBar();
      scaffoldMessenger.showSnackBar(snackBar);
    }

    setState(() {
      written = true;
    });

    updateProgress(-1);
  }

  Future<void> _showCloneVerification(
    MifareClassicCloneVerification result, {
    required bool uidChanged,
  }) async {
    final text = _randomUidText;
    final successful = result.isIdentical;
    final details = <String>[];

    if (!result.cardDetected) details.add(text.cardNotDetected);
    if (result.cardDetected && !result.uidMatches) {
      details.add(text.uidDoesNotMatch);
    }
    if (result.differentBlocks.isNotEmpty) {
      details.add(text.differentBlocks(result.differentBlocks));
    }
    if (result.unreadableBlocks.isNotEmpty) {
      details.add(text.unreadableBlocks(result.unreadableBlocks));
    }
    if (result.missingDumpBlocks.isNotEmpty) {
      details.add(text.missingDumpBlocks(result.missingDumpBlocks));
    }
    if (result.keyMismatches.isNotEmpty) {
      details.add(text.keyMismatches(result.keyMismatches));
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          successful ? Icons.verified : Icons.error_outline,
          color: successful
              ? Theme.of(dialogContext).colorScheme.primary
              : Theme.of(dialogContext).colorScheme.error,
          size: 42,
        ),
        title: Text(successful
            ? uidChanged
                ? text.cloneWithDifferentUid
                : text.perfectClone
            : text.cloneNotIdentical),
        content: Text(successful
            ? uidChanged
                ? text.allDataMatchesExceptOriginalUid(
                    bytesToHexSpace(randomUid!))
                : text.allDataMatches
            : details.join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(text.close),
          ),
        ],
      ),
    );
  }

  void onStepContinue() async {
    var localizations = AppLocalizations.of(context)!;
    var scaffoldMessenger = ScaffoldMessenger.of(context);
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    if (appState.connector!.device == ChameleonDevice.lite) {
      showDialog<String>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text(localizations.no_supported),
          content: Text(localizations.lite_no_read,
              style: const TextStyle(fontWeight: FontWeight.bold)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, localizations.ok),
              child: Text(localizations.ok),
            ),
          ],
        ),
      );

      return;
    }

    if (step != 2) {
      if (step == 1) {
        await helper?.reset();
      }
      setState(() {
        step++;
      });
    } else if (helper != null && helper!.isReady() && progress == -1) {
      SnackBar snackBar;
      updateProgress(0);

      if (!await helper!.isCompatible(getCardForWrite())) {
        snackBar = SnackBar(
          content: Text(localizations.magic_incompatible_card),
          action: SnackBarAction(
            label: localizations.continue_anyway,
            onPressed: () async {
              await writeCard();
            },
          ),
        );

        scaffoldMessenger.hideCurrentSnackBar();
        scaffoldMessenger.showSnackBar(snackBar);
      } else {
        await writeCard();
      }

      updateProgress(-1);
    }
  }

  void onStepBack() async {
    setState(() {
      written = false;
      step--;
    });

    if (step == 1) {
      await helper?.reset();
    }
  }

  void onStepReset() async {
    setState(() {
      written = false;
      step = 0;
      randomizeUid = false;
      randomUid = null;
    });
  }

  List<Widget> createButtonsForStep(ControlsDetails details, int step) {
    var localizations = AppLocalizations.of(context)!;
    List<Widget> widgets = [];

    if (written) {
      widgets.add(TextButton(
        onPressed: (progress == -1) ? onStepContinue : null,
        child: Text(localizations.write_again),
      ));

      widgets.add(TextButton(
        onPressed: (progress == -1) ? onStepReset : null,
        child: Text(localizations.reset),
      ));
    } else {
      if (step == 0 || step == 1) {
        widgets.add(TextButton(
          onPressed:
              (step == 0 && card == null || step == 1 && baseHelper == null)
                  ? null
                  : onStepContinue,
          child: Text(localizations.next),
        ));
      }

      if (step == 2) {
        widgets.add(TextButton(
          onPressed: (helper != null && helper!.isReady() && progress == -1)
              ? onStepContinue
              : null,
          child: Text(localizations.write_data_to_magic_card),
        ));
      }

      if (step != 0) {
        widgets.add(TextButton(
          onPressed: onStepBack,
          child: Text(localizations.back),
        ));
      }
    }

    return widgets;
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var typeLocalization = {
      'gen1': localizations.gen1,
      'gen2': localizations.gen2,
      'gen3': localizations.gen3,
      't55xx': localizations.t55xx,
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.write_card),
      ),
      body: SingleChildScrollView(
          child: Center(
              child: Stepper(
        physics: const ClampingScrollPhysics(),
        controlsBuilder: (BuildContext context, ControlsDetails details) {
          return Column(children: [
            const SizedBox(height: 8),
            Row(
              children: createButtonsForStep(details, step),
            )
          ]);
        },
        currentStep: step,
        steps: [
          Step(
            title: Text(localizations.select_saved_card_to_write),
            content: Card(
              child: ListTile(
                title: Row(children: [
                  FilterChip(
                    onSelected: (bool selected) {
                      cardSelectDialog(context);
                    },
                    avatar: (card != null)
                        ? CircleAvatar(
                            backgroundColor: Colors.transparent,
                            child: Icon(
                                (chameleonTagToFrequency(card!.tag) ==
                                        TagFrequency.hf)
                                    ? Icons.credit_card
                                    : Icons.wifi,
                                color: card!.color),
                          )
                        : null,
                    label: Text((card != null)
                        ? card!.name
                        : localizations.select_saved_card),
                  )
                ]),
              ),
            ),
            isActive: step >= 1,
          ),
          Step(
            title: Text(localizations.select_magic_card),
            content: Card(
              child: ListTile(
                title: (baseHelper != null)
                    ? Wrap(
                        direction: Axis.horizontal,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                            DropdownButton<AbstractWriteHelper>(
                              value: helper,
                              items: baseHelper!
                                  .getAvailableMethods()
                                  .map<DropdownMenuItem<AbstractWriteHelper>>(
                                      (AbstractWriteHelper helperClass) {
                                return DropdownMenuItem<AbstractWriteHelper>(
                                  value: helperClass,
                                  child:
                                      Text(typeLocalization[helperClass.name]!),
                                );
                              }).toList(),
                              onChanged: (AbstractWriteHelper? helperClass) {
                                setState(() {
                                  helper = helperClass;
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            if (baseHelper!.autoDetect)
                              TextButton(
                                onPressed: () async {
                                  await detectMagicType();
                                },
                                child:
                                    Text(localizations.auto_detect_magic_card),
                              )
                          ])
                    : Text(localizations.writing_is_not_yet_supported),
              ),
            ),
            isActive: step >= 2,
          ),
          Step(
            title: Text(localizations.write_data_to_magic_card),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (card != null && isMifareClassic(card!.tag)) ...[
                  Card(
                    child: Column(
                      children: [
                        CheckboxListTile(
                          value: randomizeUid,
                          onChanged: canRandomizeUid && progress == -1
                              ? (enabled) {
                                  setState(() {
                                    randomizeUid = enabled ?? false;
                                    randomUid = randomizeUid
                                        ? generateRandomUid()
                                        : null;
                                  });
                                }
                              : null,
                          title: Text(_randomUidText.optionTitle),
                          subtitle: Text(canRandomizeUid
                              ? _randomUidText.optionDescription
                              : _randomUidText.onlyFourByteDump),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (randomizeUid && randomUid != null)
                          ListTile(
                            leading: const Icon(Icons.fingerprint),
                            title: Text(_randomUidText.generatedUid),
                            subtitle: SelectableText(
                              bytesToHexSpace(randomUid!),
                              style: const TextStyle(
                                  fontFamily: 'RobotoMono', fontSize: 16),
                            ),
                            trailing: IconButton(
                              tooltip: _randomUidText.regenerate,
                              onPressed: progress == -1
                                  ? () => setState(() {
                                        randomUid = generateRandomUid();
                                      })
                                  : null,
                              icon: const Icon(Icons.refresh),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Card(
                  child: ListTile(
                    title: (progress == -1)
                        ? (helper != null && helper!.isReady())
                            ? (helper != null &&
                                    helper!.getFailedBlocks().isNotEmpty)
                                ? Text(
                                    "${localizations.otp_magic_warning(localizations.write_data_to_magic_card)} ${localizations.some_blocks_failed_to_write}: ${helper!.getFailedBlocks().join(", ")}")
                                : Text(localizations.otp_magic_warning(
                                    localizations.write_data_to_magic_card))
                            : (helper != null && helper!.writeWidgetSupported())
                                ? helper!.getWriteWidget(context, setState)
                                : Text(localizations.error)
                        : Column(
                            children: [
                              if (verifyingClone) ...[
                                Text(_randomUidText.verifyingClone),
                                const SizedBox(height: 8),
                              ],
                              LinearProgressIndicator(
                                  value: progress.toDouble() / 100),
                            ],
                          ),
                  ),
                ),
              ],
            ),
            isActive: step >= 3,
          ),
        ],
      ))),
    );
  }
}

class _RandomUidText {
  final bool italian;

  const _RandomUidText(this.italian);

  String get optionTitle =>
      italian ? 'Genera un nuovo UID casuale' : 'Generate a new random UID';
  String get optionDescription => italian
      ? 'Modifica solo UID e BCC nella copia temporanea; il resto del dump e la carta salvata rimangono invariati.'
      : 'Only UID and BCC are changed in a temporary copy; the rest of the dump and the saved card remain unchanged.';
  String get onlyFourByteDump => italian
      ? 'Disponibile solo per dump MIFARE Classic completi con UID da 4 byte.'
      : 'Available only for complete MIFARE Classic dumps with a 4-byte UID.';
  String get generatedUid => italian ? 'Nuovo UID' : 'New UID';
  String get regenerate => italian ? 'Rigenera UID' : 'Regenerate UID';
  String get verifyingClone => italian
      ? 'Verifica completa della carta scritta…'
      : 'Performing a complete verification of the written card…';
  String get perfectClone =>
      italian ? 'Carta perfettamente identica' : 'Perfectly identical card';
  String get cloneWithDifferentUid => italian
      ? 'Carta clonata con UID differente'
      : 'Card cloned with a different UID';
  String get cloneNotIdentical => italian
      ? 'La carta non è perfettamente identica'
      : 'The card is not perfectly identical';
  String get allDataMatches => italian
      ? 'Tutti i blocchi, le chiavi e le condizioni di accesso corrispondono al dump.'
      : 'All blocks, keys and access conditions match the dump.';
  String allDataMatchesExceptOriginalUid(String uid) => italian
      ? 'Tutto il dump corrisponde. Come richiesto, UID e BCC sono stati sostituiti. Nuovo UID: $uid'
      : 'The entire dump matches. As requested, UID and BCC were replaced. New UID: $uid';
  String get cardNotDetected => italian
      ? 'Carta non rilevata durante la verifica.'
      : 'Card not detected during verification.';
  String get uidDoesNotMatch => italian
      ? 'L’UID letto non corrisponde a quello che doveva essere scritto.'
      : 'The detected UID does not match the UID that should have been written.';
  String differentBlocks(List<int> blocks) => italian
      ? 'Blocchi differenti: ${_formatList(blocks)}.'
      : 'Different blocks: ${_formatList(blocks)}.';
  String unreadableBlocks(List<int> blocks) => italian
      ? 'Blocchi non leggibili: ${_formatList(blocks)}.'
      : 'Unreadable blocks: ${_formatList(blocks)}.';
  String missingDumpBlocks(List<int> blocks) => italian
      ? 'Il dump non contiene dati completi per i blocchi: ${_formatList(blocks)}.'
      : 'The dump does not contain complete data for blocks: ${_formatList(blocks)}.';
  String keyMismatches(List<String> keys) => italian
      ? 'Chiavi non confermate (settore/tipo): ${_formatList(keys)}.'
      : 'Unconfirmed keys (sector/type): ${_formatList(keys)}.';
  String get close => italian ? 'Chiudi' : 'Close';

  String _formatList(List<Object> values) {
    const visibleItems = 20;
    final visible = values.take(visibleItems).join(', ');
    final remaining = values.length - visibleItems;
    return remaining > 0 ? '$visible (+$remaining)' : visible;
  }
}
