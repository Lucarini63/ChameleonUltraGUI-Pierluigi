import 'dart:io';

import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/gui/page/read_card.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/password_audit.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

enum MifareUltralightState { none, read, save }

class MifareUltralightHelper extends StatefulWidget {
  final HFCardInfo hfInfo;
  final bool allowSave;

  const MifareUltralightHelper(
      {super.key, required this.hfInfo, this.allowSave = true});

  @override
  State<StatefulWidget> createState() => CardReaderState();
}

class CardReaderState extends State<MifareUltralightHelper> {
  TextEditingController keyController = TextEditingController();
  MifareUltralightState state = MifareUltralightState.none;
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  List<Uint8List> cardData = [];
  String version = "";
  String signature = "";
  List<int> counters = [];
  String dumpName = "";
  String error = "";
  double progress = -1;
  NtagProtectionInfo? protectionInfo;
  bool passwordAuditRunning = false;
  bool cancelPasswordAudit = false;
  int passwordAuditTried = 0;
  int passwordAuditTotal = 0;
  String passwordAuditMessage = "";
  String automaticReadMessage = "";
  Uint8List? knownPassword;

  bool get _isAutomaticNtag212 => widget.hfInfo.type == TagType.ntag212;

  @override
  void initState() {
    super.initState();
    if (_isAutomaticNtag212) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && state == MifareUltralightState.none) {
          readCard(automatic: true);
        }
      });
    }
  }

  Future<void> readCard(
      {bool withPassword = false, bool automatic = false}) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var localizations = AppLocalizations.of(context)!;
    Uint8List? pack;
    setState(() {
      cardData = [];
      error = "";
      passwordAuditMessage = "";
      if (automatic && !withPassword) {
        automaticReadMessage =
            Localizations.localeOf(context).languageCode == 'it'
                ? 'NTAG212 rilevata: lettura automatica sicura senza password.'
                : 'NTAG212 detected: safe automatic read without a password.';
      }
      state = MifareUltralightState.read;
    });

    if (withPassword) {
      final passwordText = keyController.text.trim();
      if (passwordText.length != 8 || !isValidHexString(passwordText)) {
        setState(() {
          state = MifareUltralightState.none;
          error = localizations.invalid_password;
        });
        return;
      }
      pack = await verifyNtagPassword(
          appState.communicator!, hexToBytes(passwordText),
          keepRfField: true);
      if (pack == null) {
        if (!mounted) return;
        setState(() {
          state = MifareUltralightState.none;
          error = localizations.invalid_password;
        });
        return;
      }
      knownPassword = hexToBytes(passwordText);
    }

    final totalPages = mfUltralightGetPagesCount(widget.hfInfo.type);
    for (var page = 0; page < totalPages; page++) {
      Uint8List pageData;
      try {
        pageData = await appState.communicator!.send14ARaw(
          Uint8List.fromList([0x30, page]),
          activateRfField: !withPassword,
          autoSelect: !withPassword,
          keepRfField: withPassword && page < totalPages - 1,
        );
      } catch (_) {
        pageData = Uint8List(0);
      }
      if (pageData.isNotEmpty) {
        cardData.add(Uint8List.fromList(pageData.slice(0, 4).toList()));
      } else {
        cardData.add(Uint8List(0));
      }

      setState(() {
        progress = (page + 1) / totalPages;
      });
    }

    bool hasValidData = false;
    for (var block in cardData) {
      if (block.isNotEmpty) {
        hasValidData = true;
      }
    }

    if (!hasValidData) {
      setState(() {
        progress = 0;
        cardData = [];
        error = localizations.failed_to_read_block;
        state = MifareUltralightState.none;
      });
      return;
    }

    version =
        bytesToHexSpace(await mfUltralightGetVersion(appState.communicator!));
    signature =
        bytesToHexSpace(await mfUltralightGetSignature(appState.communicator!));

    if (mfUltralightHasCounters(widget.hfInfo.type)) {
      counters = await mfUltralightReadAllCountersFromCard(
          appState.communicator!, widget.hfInfo.type);
    }

    // Save password to dump if was used
    int passwordPage = mfUltralightGetPasswordPage(widget.hfInfo.type);
    if (withPassword &&
        passwordPage >= 2 &&
        cardData.length > passwordPage - 1 &&
        cardData[passwordPage - 2].length == 4 &&
        cardData[passwordPage - 1].length == 4) {
      protectionInfo = parseNtagProtectionResponse(
        Uint8List.fromList([
          ...cardData[passwordPage - 2],
          ...cardData[passwordPage - 1],
        ]),
        totalPages,
      );
    } else {
      protectionInfo = await readNtagProtectionInfo(
          appState.communicator!, widget.hfInfo.type);
    }

    if (passwordPage != 0 && withPassword) {
      cardData[passwordPage] = hexToBytes(keyController.text);
      cardData[passwordPage + 1] = Uint8List(4);
      for (var byte = 0; byte < pack!.length; byte++) {
        cardData[passwordPage + 1][byte] = pack[byte];
      }
    }

    setState(() {
      error = "";
      state = MifareUltralightState.save;
    });

    if (automatic && _isAutomaticNtag212) {
      if (withPassword) {
        setState(() {
          automaticReadMessage =
              Localizations.localeOf(context).languageCode == 'it'
                  ? 'Lettura completata con la password verificata.'
                  : 'Read completed with the verified password.';
        });
      } else {
        await _continueAutomaticNtag212Read();
      }
    }
  }

  Uint8List? _savedPasswordForCurrentUid() {
    final appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final normalizedUid = widget.hfInfo.uid.replaceAll(' ', '').toUpperCase();
    final savedCard =
        appState.sharedPreferencesProvider.getCards().firstWhereOrNull(
              (card) =>
                  card.uid.replaceAll(' ', '').toUpperCase() == normalizedUid &&
                  card.extraData.ultralightPassword.length == 4,
            );
    if (savedCard == null) return null;
    return Uint8List.fromList(savedCard.extraData.ultralightPassword);
  }

  Future<void> _continueAutomaticNtag212Read() async {
    final italian = Localizations.localeOf(context).languageCode == 'it';
    final info = protectionInfo ??
        NtagProtectionInfo(readable: false, totalPages: cardData.length);
    final inaccessiblePages = cardData.where((page) => page.isEmpty).length;
    final decision = decideNtagAutomaticRead(
      protection: info,
      inaccessiblePages: inaccessiblePages,
    );

    switch (decision) {
      case NtagAutomaticReadDecision.completeWithoutPassword:
        setState(() {
          automaticReadMessage = italian
              ? 'Lettura completa senza password: nessun tentativo sul dizionario necessario.'
              : 'Complete read without a password: no dictionary attempt needed.';
        });
        return;
      case NtagAutomaticReadDecision.retryWithoutPassword:
        setState(() {
          automaticReadMessage = italian
              ? 'La password non protegge la lettura. Alcune pagine non sono state ricevute: nessun tentativo password eseguito.'
              : 'The password does not protect reads. Some pages were not received: no password attempt was made.';
        });
        return;
      case NtagAutomaticReadDecision.stopForSafety:
        setState(() {
          automaticReadMessage = italian
              ? 'Lettura fermata in sicurezza: AUTHLIM è attivo oppure non verificabile. Dizionario non avviato.'
              : 'Read stopped safely: AUTHLIM is enabled or cannot be verified. Dictionary not started.';
        });
        return;
      case NtagAutomaticReadDecision.authenticate:
        break;
    }

    final appState = Provider.of<ChameleonGUIState>(context, listen: false);
    Uint8List? password = _savedPasswordForCurrentUid();
    if (password != null) {
      final pack = await verifyNtagPassword(appState.communicator!, password);
      if (!mounted) return;
      if (pack == null) {
        password = null;
      }
    }

    if (password == null) {
      setState(() {
        automaticReadMessage = italian
            ? 'Lettura protetta e AUTHLIM=0: controllo automatico del dizionario NTAG.'
            : 'Read protection with AUTHLIM=0: checking the NTAG dictionary automatically.';
      });
      password = await auditPasswordDictionary();
      if (!mounted) return;
    }

    if (password == null) {
      setState(() {
        automaticReadMessage = italian
            ? 'Nessuna password valida trovata: conservata la lettura parziale senza altri tentativi.'
            : 'No valid password found: the partial read was kept without further attempts.';
      });
      return;
    }

    knownPassword = Uint8List.fromList(password);
    keyController.text = bytesToHex(password).toUpperCase();
    await readCard(withPassword: true, automatic: true);
  }

  Future<Uint8List?> auditPasswordDictionary() async {
    final info = protectionInfo;
    if (info == null || !info.dictionaryAuditAllowed || passwordAuditRunning) {
      return null;
    }

    final appState = Provider.of<ChameleonGUIState>(context, listen: false);
    final italian = Localizations.localeOf(context).languageCode == 'it';
    final passwords = await loadNtagAuditDictionary();
    if (!mounted) return null;

    setState(() {
      passwordAuditRunning = true;
      cancelPasswordAudit = false;
      passwordAuditTried = 0;
      passwordAuditTotal = passwords.length;
      passwordAuditMessage = "";
    });

    Uint8List? found;
    for (final password in passwords) {
      if (cancelPasswordAudit) break;
      final pack = await verifyNtagPassword(appState.communicator!, password);
      if (!mounted) return null;
      setState(() => passwordAuditTried++);
      if (pack != null) {
        found = password;
        break;
      }
    }

    if (!mounted) return null;
    setState(() {
      passwordAuditRunning = false;
      if (found != null) {
        knownPassword = Uint8List.fromList(found);
        keyController.text = bytesToHex(found).toUpperCase();
        passwordAuditMessage = italian
            ? 'Password trovata e associata a questo dump: ${keyController.text}'
            : 'Password found and associated with this dump: ${keyController.text}';
      } else if (cancelPasswordAudit) {
        passwordAuditMessage =
            italian ? 'Verifica annullata.' : 'Audit cancelled.';
      } else {
        passwordAuditMessage = italian
            ? 'Nessuna password del dizionario è valida.'
            : 'No password in the dictionary is valid.';
      }
    });
    return found;
  }

  Future<void> saveCard({bool bin = false}) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    List<int> cardDump = [];
    var localizations = AppLocalizations.of(context)!;
    for (var page = 0;
        page < mfUltralightGetPagesCount(widget.hfInfo.type);
        page++) {
      if (cardData[page].isEmpty) {
        cardDump.addAll(Uint8List(4));
      } else {
        cardDump.addAll(cardData[page]);
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
          tag: widget.hfInfo.type,
          data: cardData,
          extraData: CardSaveExtra(
            ultralightSignature: hexToBytes(signature),
            ultralightVersion: hexToBytes(version),
            ultralightPassword: knownPassword,
            ultralightCounters: counters,
          ),
          ats: (widget.hfInfo.ats != localizations.no)
              ? hexToBytes(widget.hfInfo.ats)
              : Uint8List(0)));
      appState.sharedPreferencesProvider.setCards(tags);
    }
  }

  Widget buildProtectionPanel() {
    final italian = Localizations.localeOf(context).languageCode == 'it';
    final info = protectionInfo;
    if (info == null) return const SizedBox.shrink();

    final readablePages = cardData.where((page) => page.isNotEmpty).length;
    final inaccessiblePages = cardData.length - readablePages;
    final children = <Widget>[
      Text(
        italian ? 'Analisi dump NTAG' : 'NTAG dump analysis',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      Text(italian
          ? 'Pagine lette: $readablePages/${cardData.length} · non accessibili: $inaccessiblePages'
          : 'Pages read: $readablePages/${cardData.length} · inaccessible: $inaccessiblePages'),
      const SizedBox(height: 6),
    ];

    if (!info.readable) {
      children.add(Text(
        italian
            ? 'Configurazione di protezione non leggibile: il controllo dizionario è disabilitato per evitare un blocco permanente.'
            : 'Protection configuration is unreadable: dictionary audit is disabled to avoid permanent lockout.',
        textAlign: TextAlign.center,
      ));
    } else if (!info.protectionEnabled) {
      children.add(Text(italian
          ? 'Protezione password disattivata (AUTH0 fuori memoria).'
          : 'Password protection is disabled (AUTH0 outside memory).'));
    } else {
      children.addAll([
        Text(
          'AUTH0: ${info.auth0} · PROT: ${info.protectsRead ? 'R/W' : 'W'} · AUTHLIM: ${info.authLimit}',
        ),
        if (info.configurationLocked)
          Text(italian
              ? 'Configurazione bloccata in scrittura (CFGLCK).'
              : 'Configuration is write-locked (CFGLCK).'),
        const SizedBox(height: 8),
      ]);

      if ((info.authLimit ?? 0) > 0) {
        children.add(Text(
          italian
              ? 'Controllo dizionario non consentito: AUTHLIM è attivo e gli errori possono bloccare permanentemente l’area protetta.'
              : 'Dictionary audit is not allowed: AUTHLIM is active and failures can permanently lock the protected area.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ));
      } else if (info.dictionaryAuditAllowed) {
        children.add(
          passwordAuditRunning
              ? Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: passwordAuditTotal == 0
                            ? null
                            : passwordAuditTried / passwordAuditTotal,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$passwordAuditTried/$passwordAuditTotal'),
                    TextButton(
                      onPressed: () => setState(() {
                        cancelPasswordAudit = true;
                      }),
                      child: Text(italian ? 'Annulla' : 'Cancel'),
                    ),
                  ],
                )
              : ElevatedButton.icon(
                  onPressed: auditPasswordDictionary,
                  icon: const Icon(Icons.security),
                  label: Text(italian
                      ? 'Verifica dizionario NTAG (${ntagAuditDictionaryAsset.split('/').last})'
                      : 'Audit NTAG dictionary (${ntagAuditDictionaryAsset.split('/').last})'),
                ),
        );
      }
    }

    if (passwordAuditMessage.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 8),
        SelectableText(passwordAuditMessage, textAlign: TextAlign.center),
      ]);
    }
    if (automaticReadMessage.isNotEmpty) {
      children.addAll([
        const SizedBox(height: 8),
        SelectableText(automaticReadMessage, textAlign: TextAlign.center),
      ]);
    }
    if (knownPassword != null && state == MifareUltralightState.save) {
      children.add(TextButton(
        onPressed: () => readCard(withPassword: true),
        child: Text(italian
            ? 'Rileggi il dump con la password verificata'
            : 'Read dump again with verified password'),
      ));
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: children),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var localizations = AppLocalizations.of(context)!;

    return Column(
      children: [
        const SizedBox(height: 16),
        if (state == MifareUltralightState.none) ...[
          Form(
            key: formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: TextFormField(
              controller: keyController,
              decoration: InputDecoration(
                  labelText: localizations.key,
                  hintMaxLines: 4,
                  hintText: localizations
                      .enter_something(localizations.ultralight_key_prompt)),
              inputFormatters: hexFormatter,
              validator: (value) => validateHex(value, localizations,
                  exactBytes: 4, fieldName: localizations.key),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: () async => {await readCard(withPassword: true)},
                child: Text(localizations.read_with_key),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () async => {await readCard(withPassword: false)},
                child: Text(localizations.read_without_key),
              ),
            ),
          ]),
        ],
        if (error != "") ...[
          const SizedBox(height: 16),
          ErrorMessage(errorMessage: error),
        ],
        if (state == MifareUltralightState.read) ...[
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8)
        ],
        if (state == MifareUltralightState.save) ...[
          buildProtectionPanel(),
          Center(
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
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
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    await saveCard(bin: true);
                  },
                  style: customCardButtonStyle(appState),
                  child: Text(localizations.save_as(".bin")),
                ),
              ])),
        ],
      ],
    );
  }
}
