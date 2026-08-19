import 'package:chameleonultragui/gui/component/card_button.dart';
import 'package:chameleonultragui/gui/component/mifare/classic.dart';
import 'package:chameleonultragui/gui/component/error_message.dart';
import 'package:chameleonultragui/gui/component/mifare/ultralight.dart';
import 'package:chameleonultragui/gui/menu/tools/sniffing_lf.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:chameleonultragui/helpers/mifare_desfire/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

enum MifareClassicState {
  none,
  checkKeys,
  checkKeysOngoing,
  recovery,
  recoveryOngoing,
  dump,
  dumpOngoing,
  save
}

// cardExist true because we don't show error to user if nothing is done
class HFCardInfo {
  String uid;
  String sak;
  String atqa;
  String tech;
  String ats;
  TagType type;
  bool cardExist;
  MifareDesfireInfo? desfireInfo;

  HFCardInfo(
      {this.uid = '',
      this.sak = '',
      this.atqa = '',
      this.tech = '',
      this.ats = '',
      this.type = TagType.unknown,
      this.cardExist = true,
      this.desfireInfo});
}

class LFCardInfo {
  LFCard? card;
  bool cardExist;

  LFCardInfo({this.cardExist = true});
}

class MifareClassicInfo {
  bool isEV1;
  MifareClassicRecovery? recovery;
  MifareClassicType type;
  MifareClassicState state;
  NTLevel? ntLevel;
  bool? hasBackdoor;

  MifareClassicInfo({
    MifareClassicRecovery? recovery,
    this.isEV1 = false,
    this.type = MifareClassicType.none,
    this.state = MifareClassicState.none,
    NTLevel? ntLevel,
    bool? hasBackdoor,
  });
}

class MifareUltralightInfo {
  Uint8List? version;
  Uint8List? signature;

  MifareUltralightInfo();
}

class ReadCardPage extends StatefulWidget {
  const ReadCardPage({super.key});

  @override
  ReadCardPageState createState() => ReadCardPageState();
}

class ReadCardPageState extends State<ReadCardPage> {
  String dumpName = "";
  HFCardInfo hfInfo = HFCardInfo();
  LFCardInfo lfInfo = LFCardInfo();
  MifareClassicInfo mfcInfo = MifareClassicInfo();
  MifareUltralightInfo mfuInfo = MifareUltralightInfo();

  bool isContinuousHFScan = false;
  bool isContinuousLFScan = false;
  bool scanInProgress = false;

  void updateMifareClassicRecovery() {
    setState(() {
      mfcInfo.recovery = mfcInfo.recovery;
    });
  }

  void updateMifareClassicInfo() {
    setState(() {
      mfcInfo = mfcInfo;
    });
  }

  Future<void> readLFInfo() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    setState(() {
      lfInfo = LFCardInfo();
    });

    if (!await appState.communicator!.isReaderDeviceMode()) {
      await appState.communicator!.setReaderDeviceMode(true);
    }

    LFCard? card = await appState.communicator!.readEM410X();
    card ??= await appState.communicator!.readHIDProx();
    card ??= await appState.communicator!.readViking();

    if (!mounted) return;

    if (card != null) {
      setState(() {
        lfInfo.card = card;
        scanInProgress = false;
      });
    } else {
      setState(() {
        lfInfo.cardExist = false;
        scanInProgress = false;
      });
    }
  }

  Future<void> startContinuousHFScan() async {
    if (isContinuousHFScan) return;

    setState(() {
      isContinuousHFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    final deadline = DateTime.now().add(const Duration(minutes: 1));

    while (mounted && isContinuousHFScan && DateTime.now().isBefore(deadline)) {
      if (!mounted) return;
      final info = await readHFInfo(context, updateMifareClassicRecovery);
      if (!mounted || !isContinuousHFScan) return;

      setState(() {
        hfInfo = info.$1;
        mfcInfo = info.$2;
        mfuInfo = info.$3;
      });

      if (hfInfo.cardExist && hfInfo.uid.isNotEmpty) {
        stopContinuousHFScan();
        return;
      }

      await Future<void>.delayed(scanInterval);
    }

    stopContinuousHFScan();
  }

  void stopContinuousHFScan() {
    if (!isContinuousHFScan) return;
    if (!mounted) {
      isContinuousHFScan = false;
      return;
    }
    setState(() {
      isContinuousHFScan = false;
    });
  }

  Future<void> startContinuousLFScan() async {
    if (isContinuousLFScan) return;

    setState(() {
      isContinuousLFScan = true;
    });

    const scanInterval = Duration(seconds: 2);
    final deadline = DateTime.now().add(const Duration(minutes: 1));

    while (mounted && isContinuousLFScan && DateTime.now().isBefore(deadline)) {
      await readLFInfo();
      if (!mounted || !isContinuousLFScan) return;

      if (lfInfo.cardExist && lfInfo.card != null) {
        stopContinuousLFScan();
        return;
      }

      await Future<void>.delayed(scanInterval);
    }

    stopContinuousLFScan();
  }

  void stopContinuousLFScan() {
    if (!isContinuousLFScan) return;
    if (!mounted) {
      isContinuousLFScan = false;
      return;
    }
    setState(() {
      isContinuousLFScan = false;
    });
  }

  @override
  void dispose() {
    isContinuousHFScan = false;
    isContinuousLFScan = false;
    super.dispose();
  }

  Future<void> saveHFCard() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    var localizations = AppLocalizations.of(context)!;

    var tags = appState.sharedPreferencesProvider.getCards();
    tags.add(CardSave(
      uid: hfInfo.uid,
      sak: hexToBytes(hfInfo.sak)[0],
      atqa: hexToBytes(hfInfo.atqa),
      name: dumpName,
      tag: hfInfo.type != TagType.unknown ? hfInfo.type : TagType.mifare1K,
      data: [],
      ats: (hfInfo.ats != localizations.no)
          ? hexToBytes(hfInfo.ats)
          : Uint8List(0),
      extraData: CardSaveExtra(
        ultralightSignature: mfuInfo.signature,
        ultralightVersion: mfuInfo.version,
        ultralightCounters: [],
      ),
    ));

    appState.sharedPreferencesProvider.setCards(tags);
  }

  Future<void> saveLFCard() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    var tags = appState.sharedPreferencesProvider.getCards();
    tags.add(CardSave(
        uid: lfInfo.card.toString(), name: dumpName, tag: lfInfo.card!.type));
    appState.sharedPreferencesProvider.setCards(tags);
  }

  Widget buildFieldRow(String label, String value, double fontSize) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(
        '$label: $value',
        textAlign: (MediaQuery.of(context).size.width < 800)
            ? TextAlign.left
            : TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }

  Widget buildLfCredentialAnalysis(LFCard card) {
    final italian = Localizations.localeOf(context).languageCode == 'it';
    if (card is! HIDCard) {
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: Text(italian ? 'Identificativo LF' : 'LF identifier'),
          subtitle: SelectableText(card.toViewableString()),
        ),
      );
    }

    Widget valueRow(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    SelectableText(value),
                  ],
                ),
              ),
            ],
          ),
        );

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.verified_user_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    italian ? 'Credenziale LF rilevata' : 'LF credential found',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            valueRow(Icons.tune, italian ? 'Formato' : 'Format',
                getNameForHIDProxType(card.hidType)),
            valueRow(
                Icons.apartment,
                italian ? 'Codice impianto (Facility Code)' : 'Facility code',
                card.facilityCode.toString()),
            valueRow(
                Icons.numbers,
                italian ? 'Numero credenziale' : 'Credential number',
                card.credentialNumber.toString()),
            const Divider(height: 22),
            Text(
              italian
                  ? 'Questa credenziale trasmette un identificativo; non possiede pagine di memoria come una carta HF.'
                  : 'This credential transmits an identifier; it has no memory pages like an HF card.',
              textAlign: TextAlign.center,
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text(italian ? 'Dati tecnici' : 'Technical data'),
              children: [
                valueRow(Icons.code, 'UID hex', bytesToHexSpace(card.uid)),
                valueRow(
                    Icons.data_object,
                    italian ? 'Codice formato' : 'Format code',
                    card.hidType.toString()),
                valueRow(Icons.low_priority, 'Issue Level',
                    card.issueLevel.toString()),
                valueRow(Icons.business, 'OEM', card.oem.toString()),
                valueRow(
                    Icons.memory,
                    italian ? 'Dati interni codificati' : 'Encoded data',
                    card.toString()),
              ],
            ),
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const LFSniffingMenu(),
              ),
              icon: const Icon(Icons.graphic_eq),
              label: Text(italian
                  ? 'Apri analisi avanzata LF'
                  : 'Open advanced LF analysis'),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDesfireDetails(MifareDesfireInfo info, double fontSize) {
    final italian = Localizations.localeOf(context).languageCode == 'it';
    String hexByte(int? value) => value == null
        ? '-'
        : '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';

    if (!info.confirmed) {
      if (info.apduSupported) return const SizedBox.shrink();
      return Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            italian
                ? 'Carta ISO/IEC 14443-4 rilevata. Per confermare MIFARE '
                    'DESFire serve un firmware con supporto APDU 6004.'
                : 'ISO/IEC 14443-4 card detected. Firmware with APDU command '
                    '6004 is required to confirm MIFARE DESFire.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final storage = info.storageBytes;
    final storageText = storage == null
        ? '-'
        : '${info.isExactStorageSize ? '' : '≈ '}$storage byte';
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              info.displayName,
              style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            buildFieldRow(
                italian ? 'Cifratura AES' : 'AES encryption',
                info.supportsAes
                    ? (italian ? 'Supportata' : 'Supported')
                    : (italian ? 'Non confermata' : 'Not confirmed'),
                fontSize * 0.8),
            buildFieldRow(
                italian ? 'Versione hardware' : 'Hardware version',
                '${hexByte(info.hardwareMajor)} / ${hexByte(info.hardwareMinor)}',
                fontSize * 0.8),
            buildFieldRow(italian ? 'Memoria indicata' : 'Reported memory',
                storageText, fontSize * 0.8),
            buildFieldRow(italian ? 'Tipo prodotto' : 'Product type',
                hexByte(info.hardwareType), fontSize * 0.8),
            if (info.versionFrame != null)
              buildFieldRow('GetVersion', bytesToHexSpace(info.versionFrame!),
                  fontSize * 0.72),
            Text(
              italian
                  ? 'Identificazione in sola lettura: nessuna autenticazione '
                      'o modifica della carta è stata eseguita.'
                  : 'Read-only identification: no authentication or card '
                      'modification was performed.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: fontSize * 0.72),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    var localizations = AppLocalizations.of(context)!;
    final isSmallScreen = screenSize.width < 800;

    double fieldFontSize = isSmallScreen ? 16 : 20;

    var appState = context.watch<ChameleonGUIState>();

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.read_card),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Center(
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        localizations.hf_tag_info,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      buildFieldRow(
                          localizations.uid, hfInfo.uid, fieldFontSize),
                      buildFieldRow(
                          localizations.sak, hfInfo.sak, fieldFontSize),
                      buildFieldRow(
                          localizations.atqa, hfInfo.atqa, fieldFontSize),
                      buildFieldRow(
                          localizations.ats, hfInfo.ats, fieldFontSize),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${localizations.card_tech}: ${hfInfo.tech}',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: fieldFontSize),
                          ),
                          if (hfInfo.uid.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (BuildContext context) {
                                    return AlertDialog(
                                      title: Text(
                                          localizations.override_card_type),
                                      content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            localizations
                                                .override_card_type_description,
                                            style:
                                                const TextStyle(fontSize: 14),
                                          ),
                                          const SizedBox(height: 16),
                                          DropdownButton<TagType?>(
                                            isExpanded: true,
                                            value: hfInfo.type,
                                            onChanged:
                                                (TagType? newValue) async {
                                              setState(() {
                                                hfInfo.type = newValue!;
                                                hfInfo.tech =
                                                    chameleonTagToString(
                                                        newValue,
                                                        localizations);
                                              });

                                              if (isMifareClassic(newValue!)) {
                                                var info =
                                                    await performMifareClassicScan(
                                                        appState.communicator!,
                                                        mfcInfo,
                                                        context,
                                                        updateMifareClassicRecovery,
                                                        override: newValue);
                                                setState(() {
                                                  mfcInfo = info.$2;
                                                });
                                              } else if (isMifareUltralight(
                                                  newValue)) {
                                                var info =
                                                    await performMifareUltralightScan(
                                                        appState.communicator!,
                                                        mfuInfo,
                                                        override: newValue);
                                                setState(() {
                                                  mfuInfo = info.$2;
                                                });
                                              }

                                              if (context.mounted) {
                                                Navigator.of(context).pop();
                                              }
                                            },
                                            items: [
                                              ...[
                                                ...getTagTypesByFrequency(
                                                    TagFrequency.hf),
                                                if (hfInfo.type ==
                                                    TagType.mifareDesfire)
                                                  TagType.mifareDesfire,
                                                TagType.unknown
                                              ].map((TagType tagType) {
                                                return DropdownMenuItem<
                                                    TagType?>(
                                                  value: tagType,
                                                  child: Text(
                                                      chameleonTagToString(
                                                          tagType,
                                                          localizations)),
                                                );
                                              }),
                                            ],
                                          ),
                                        ],
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child: Text(localizations.cancel),
                                        ),
                                      ],
                                    );
                                  },
                                );
                              },
                              icon: const Icon(Icons.edit),
                              iconSize: 20,
                              padding: const EdgeInsets.all(4),
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: localizations.override_card_type,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (hfInfo.desfireInfo != null) ...[
                        buildDesfireDetails(hfInfo.desfireInfo!, fieldFontSize),
                        const SizedBox(height: 16),
                      ],
                      if (isMifareClassic(hfInfo.type)) ...[
                        if (mfcInfo.ntLevel != null)
                          buildFieldRow(
                              localizations.prng_type,
                              mfClassicGetPrngType(
                                  mfcInfo.ntLevel!, localizations),
                              fieldFontSize),
                        if (mfcInfo.hasBackdoor != null)
                          buildFieldRow(
                              localizations.has_backdoor_support,
                              mfcInfo.hasBackdoor!
                                  ? localizations.yes
                                  : localizations.no,
                              fieldFontSize),
                        const SizedBox(height: 16),
                      ],
                      isSmallScreen
                          ? Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: scanInProgress
                                        ? null
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              setState(() {
                                                scanInProgress = true;
                                              });
                                              var info = await readHFInfo(
                                                  context,
                                                  updateMifareClassicRecovery);
                                              setState(() {
                                                hfInfo = info.$1;
                                                mfcInfo = info.$2;
                                                mfuInfo = info.$3;
                                                scanInProgress = false;
                                              });
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: isContinuousHFScan
                                        ? () => stopContinuousHFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousHFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousHFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      if (appState.connector!.device ==
                                          ChameleonDevice.ultra) {
                                        var info = await readHFInfo(context,
                                            updateMifareClassicRecovery);
                                        setState(() {
                                          hfInfo = info.$1;
                                          mfcInfo = info.$2;
                                          mfuInfo = info.$3;
                                        });
                                      } else if (appState.connector!.device ==
                                          ChameleonDevice.lite) {
                                        showDialog<String>(
                                          context: context,
                                          builder: (BuildContext context) =>
                                              AlertDialog(
                                            title: Text(
                                                localizations.no_supported),
                                            content: Text(
                                                localizations.lite_no_read,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            actions: <Widget>[
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, localizations.ok),
                                                child: Text(localizations.ok),
                                              ),
                                            ],
                                          ),
                                        );
                                      } else {
                                        appState.changesMade();
                                      }
                                    },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: isContinuousHFScan
                                        ? () => stopContinuousHFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousHFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousHFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            ),
                      if (!hfInfo.cardExist) ...[
                        const SizedBox(height: 16),
                        ErrorMessage(errorMessage: localizations.no_card_found)
                      ],
                      if (hfInfo.uid != "") ...[
                        const SizedBox(height: 16),
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
                                        await saveHFCard();
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
                          child: Text(localizations.save_only_uid),
                        ),
                      ],
                      if (isMifareClassic(hfInfo.type))
                        MifareClassicHelper(
                            mfcInfo: mfcInfo,
                            hfInfo: hfInfo,
                            onlySelectedDictionary: true,
                            autoRecoverMissingKeys: true),
                      if (isMifareUltralight(hfInfo.type))
                        MifareUltralightHelper(hfInfo: hfInfo)
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        localizations.lf_tag_info,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (lfInfo.card != null && lfInfo.card is! HIDCard) ...[
                        buildFieldRow(localizations.uid,
                            lfInfo.card!.toViewableString(), fieldFontSize),
                        const SizedBox(height: 16),
                      ],
                      Text(
                        '${localizations.card_tech}: ${(lfInfo.card != null ? chameleonTagToString(lfInfo.card!.type, localizations) : '')}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: fieldFontSize),
                      ),
                      if (lfInfo.card != null) ...[
                        const SizedBox(height: 12),
                        buildLfCredentialAnalysis(lfInfo.card!),
                      ],
                      const SizedBox(height: 16),
                      isSmallScreen
                          ? Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: scanInProgress
                                        ? null
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              setState(() {
                                                scanInProgress = true;
                                              });
                                              await readLFInfo();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: isContinuousLFScan
                                        ? () => stopContinuousLFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousLFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousLFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () async {
                                      if (appState.connector!.device ==
                                          ChameleonDevice.ultra) {
                                        await readLFInfo();
                                      } else if (appState.connector!.device ==
                                          ChameleonDevice.lite) {
                                        showDialog<String>(
                                          context: context,
                                          builder: (BuildContext context) =>
                                              AlertDialog(
                                            title: Text(
                                                localizations.no_supported),
                                            content: Text(
                                                localizations.lite_no_read,
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            actions: <Widget>[
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, localizations.ok),
                                                child: Text(localizations.ok),
                                              ),
                                            ],
                                          ),
                                        );
                                      } else {
                                        appState.changesMade();
                                      }
                                    },
                                    style: customCardButtonStyle(appState),
                                    child: Text(localizations.read),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: isContinuousLFScan
                                        ? () => stopContinuousLFScan()
                                        : () async {
                                            if (appState.connector!.device ==
                                                ChameleonDevice.ultra) {
                                              await startContinuousLFScan();
                                            } else if (appState
                                                    .connector!.device ==
                                                ChameleonDevice.lite) {
                                              showDialog<String>(
                                                context: context,
                                                builder:
                                                    (BuildContext context) =>
                                                        AlertDialog(
                                                  title: Text(localizations
                                                      .no_supported),
                                                  content: Text(
                                                      localizations
                                                          .lite_no_read,
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  actions: <Widget>[
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(context,
                                                              localizations.ok),
                                                      child: Text(
                                                          localizations.ok),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              appState.changesMade();
                                            }
                                          },
                                    style: customCardButtonStyle(appState),
                                    child: Text(isContinuousLFScan
                                        ? localizations.cancel
                                        : localizations.continuous_scan),
                                  ),
                                ),
                              ],
                            ),
                      if (!lfInfo.cardExist) ...[
                        const SizedBox(height: 16),
                        ErrorMessage(errorMessage: localizations.no_card_found)
                      ],
                      if (lfInfo.card != null) ...[
                        const SizedBox(height: 16),
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
                                        await saveLFCard();
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
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
