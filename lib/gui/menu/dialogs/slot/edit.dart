import 'package:chameleonultragui/gui/component/error_page.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/gui/menu/pages/mfkey32.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:chameleonultragui/helpers/validators.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

enum _SlotSetupMode { manual, mfkey32 }

class SlotEditMenu extends StatefulWidget {
  final String name;
  final bool isEnabled;
  final TagType slotType;
  final TagFrequency frequency;
  final int slot;
  final dynamic update;

  const SlotEditMenu(
      {super.key,
      required this.name,
      required this.isEnabled,
      required this.slotType,
      required this.frequency,
      required this.slot,
      required this.update});

  @override
  SlotEditMenuState createState() => SlotEditMenuState();
}

class SlotEditMenuState extends State<SlotEditMenu> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  TextEditingController nameController = TextEditingController();
  TextEditingController uidController = TextEditingController();
  TextEditingController sakController = TextEditingController();
  TextEditingController atqaController = TextEditingController();
  TextEditingController atsController = TextEditingController();

  TextEditingController ultralightVersionController = TextEditingController();
  TextEditingController ultralightSignatureController = TextEditingController();
  List<TextEditingController> ultralightCounterControllers = [];

  TextEditingController hidTypeController = TextEditingController();
  TextEditingController facilityCodeController = TextEditingController();
  TextEditingController issueLevelController = TextEditingController();
  TextEditingController oemController = TextEditingController();

  TagType? selectedType;
  TagType previousTagType = TagType.unknown;
  EmulatorSettings? emulatorSettings;
  int detectionCount = 0;
  _SlotSetupMode _setupMode = _SlotSetupMode.manual;
  bool _configuringMfkey32 = false;
  bool _mfkey32Configured = false;
  String? _mfkey32SetupError;

  _Mfkey32SlotText get _mfkey32Text => _Mfkey32SlotText(
      Localizations.localeOf(context).languageCode.toLowerCase() == 'it');

  @override
  void initState() {
    super.initState();
    selectedType = widget.slotType;
    nameController.text = widget.name;
  }

  Future<void> updateInfo() async {
    var appState = context.watch<ChameleonGUIState>();
    if (previousTagType == selectedType ||
        isMifareClassic(previousTagType) && isMifareClassic(selectedType!)) {
      return;
    }

    await appState.communicator!.activateSlot(widget.slot);

    if (isEM410X(selectedType!)) {
      try {
        uidController.text =
            bytesToHexSpace(await appState.communicator!.getEM410XEmulatorID());
      } catch (_) {}
    } else if (selectedType! == TagType.hidProx) {
      try {
        HIDCard hidCard = await appState.communicator!.getHIDProxEmulatorID();
        uidController.text = bytesToHexSpace(hidCard.uid);
        hidTypeController.text = hidCard.hidType.toString();
        facilityCodeController.text = hidCard.facilityCode.toString();
        issueLevelController.text = hidCard.issueLevel.toString();
        oemController.text = hidCard.oem.toString();
      } catch (_) {}
    } else if (selectedType! == TagType.viking) {
      try {
        VikingCard vikingCard =
            await appState.communicator!.getVikingEmulatorID();
        uidController.text = bytesToHexSpace(vikingCard.uid);
      } catch (_) {}
    } else if (isMifareClassic(selectedType!) ||
        isMifareUltralight(selectedType!)) {
      try {
        CardData data = await appState.communicator!.mf1GetAntiCollData();
        uidController.text = bytesToHexSpace(data.uid);
        sakController.text = bytesToHex(u8ToBytes(data.sak));
        atqaController.text = bytesToHexSpace(data.atqa);
        atsController.text = bytesToHexSpace(data.ats);

        if (isMifareClassic(selectedType!)) {
          emulatorSettings =
              await appState.communicator!.getMf1EmulatorSettings();

          if (emulatorSettings!.isDetectionEnabled) {
            detectionCount =
                await appState.communicator!.getMf1DetectionCount();
          }
          _setupMode = emulatorSettings!.isDetectionEnabled
              ? _SlotSetupMode.mfkey32
              : _SlotSetupMode.manual;
        } else if (isMifareUltralight(selectedType!)) {
          Uint8List version =
              await appState.communicator!.mf0EmulatorGetVersionData();
          ultralightVersionController.text = bytesToHexSpace(version);

          Uint8List signature =
              await appState.communicator!.mf0EmulatorGetSignatureData();
          ultralightSignatureController.text = bytesToHexSpace(signature);

          if (mfUltralightHasCounters(selectedType!)) {
            ultralightCounterControllers.clear();
            int counterCount = mfUltralightGetCounterCount(selectedType!);

            for (int i = 0; i < counterCount; i++) {
              TextEditingController controller = TextEditingController();
              var counterData =
                  await appState.communicator!.mf0EmulatorGetCounterData(i);
              controller.text = counterData.$1.toString();
              ultralightCounterControllers.add(controller);
            }
          }

          emulatorSettings =
              await appState.communicator!.mf0NtagGetEmulatorConfig();

          if (emulatorSettings!.isDetectionEnabled) {
            detectionCount =
                await appState.communicator!.mf0NtagGetDetectionCount();
          }
        }
      } catch (_) {}
    }

    setState(() {
      previousTagType = selectedType!;
    });
  }

  Future<bool> _confirmMfkey32Setup() async {
    final text = _mfkey32Text;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(text.setupTitle),
            content: Text(text.presentOriginalCard),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(text.cancel),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.contactless),
                label: Text(text.readAndConfigure),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _configureMfkey32() async {
    final text = _mfkey32Text;
    if (!await _confirmMfkey32Setup() || !mounted) return;

    setState(() {
      _configuringMfkey32 = true;
      _mfkey32SetupError = null;
    });

    final appState = context.read<ChameleonGUIState>();
    final communicator = appState.communicator!;
    var readerModeEnabled = false;

    try {
      await communicator.setReaderDeviceMode(true);
      readerModeEnabled = true;

      final card = await communicator.scan14443aTag();
      if (card == null) throw Exception(text.noCardFound);
      if (!await communicator.detectMf1Support()) {
        throw Exception(text.notMifareClassic);
      }

      final classicType = await mfClassicGetType(communicator);
      final tagType = mfClassicGetChameleonTagType(classicType);
      if (!isMifareClassic(tagType)) {
        throw Exception(text.unsupportedClassic);
      }

      await communicator.setReaderDeviceMode(false);
      readerModeEnabled = false;
      await communicator.activateSlot(widget.slot);

      final oldType = selectedType ?? widget.slotType;
      await communicator.setSlotType(widget.slot, tagType);
      if (!isMifareClassic(oldType)) {
        await communicator.setDefaultDataToSlot(widget.slot, tagType);
      }

      await communicator.setMf1AntiCollision(card);
      await communicator.setMf1DetectionStatus(true);
      await communicator.enableSlot(widget.slot, TagFrequency.hf, true);

      final uid = bytesToHex(card.uid).toUpperCase();
      final automaticName = 'MFKEY32 $uid';
      final generatedName = automaticName.length <= maxNameLength
          ? automaticName
          : automaticName.substring(0, maxNameLength);
      await communicator.setSlotTagName(
          widget.slot, generatedName, TagFrequency.hf);
      await communicator.saveSlotData();

      final settings = await communicator.getMf1EmulatorSettings();
      settings.isDetectionEnabled = true;

      if (!mounted) return;
      setState(() {
        selectedType = tagType;
        previousTagType = tagType;
        nameController.text = generatedName;
        uidController.text = bytesToHexSpace(card.uid);
        sakController.text = bytesToHex(u8ToBytes(card.sak));
        atqaController.text = bytesToHexSpace(card.atqa);
        atsController.text = bytesToHexSpace(card.ats);
        emulatorSettings = settings;
        detectionCount = 0;
        _setupMode = _SlotSetupMode.mfkey32;
        _mfkey32Configured = true;
        _configuringMfkey32 = false;
      });
      widget.update(generatedName, TagFrequency.hf, tagType);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _setupMode = _SlotSetupMode.manual;
        _configuringMfkey32 = false;
        _mfkey32SetupError = error.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (readerModeEnabled) {
        try {
          await communicator.setReaderDeviceMode(false);
        } catch (_) {}
      }
    }
  }

  Future<void> save() async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);

    await appState.communicator!.activateSlot(widget.slot);
    if (widget.slotType != selectedType && !_mfkey32Configured) {
      await appState.communicator!.setSlotType(widget.slot, selectedType!);
      bool oldIsClassic = isMifareClassic(widget.slotType);
      bool newIsClassic = isMifareClassic(selectedType!);
      bool oldIsUltralight = isMifareUltralight(widget.slotType);
      bool newIsUltralight = isMifareUltralight(selectedType!);

      if (!((oldIsClassic && newIsClassic) ||
          (oldIsUltralight && newIsUltralight))) {
        await appState.communicator!
            .setDefaultDataToSlot(widget.slot, selectedType!);
      }
    }

    if (isEM410X(selectedType!)) {
      await appState.communicator!
          .setEM410XEmulatorID(hexToBytes(uidController.text));
    } else if (selectedType! == TagType.hidProx) {
      try {
        int hidType = int.parse(hidTypeController.text);
        int facilityCode = int.parse(facilityCodeController.text);
        int issueLevel = int.parse(issueLevelController.text);
        int oem = int.parse(oemController.text);

        Uint8List uid = hexToBytes(uidController.text.replaceAll(' ', ''));

        HIDCard hidCard = HIDCard(
          hidType: hidType,
          facilityCode: facilityCode,
          uid: uid,
          issueLevel: issueLevel,
          oem: oem,
        );

        await appState.communicator!
            .setHIDProxEmulatorID(hexToBytes(hidCard.toString()));
      } catch (_) {}
    } else if (isMifareClassic(selectedType!) ||
        isMifareUltralight(selectedType!)) {
      var cardData = CardData(
          uid: hexToBytes(uidController.text),
          atqa: hexToBytes(atqaController.text),
          sak: bytesToU8(hexToBytes(sakController.text)),
          ats: hexToBytes(atsController.text));
      await appState.communicator!.setMf1AntiCollision(cardData);

      // Save Ultralight-specific data
      if (isMifareUltralight(selectedType!)) {
        await appState.communicator!.mf0EmulatorSetVersionData(
            hexToBytes(ultralightVersionController.text));

        await appState.communicator!.mf0EmulatorSetSignatureData(
            hexToBytes(ultralightSignatureController.text));

        if (mfUltralightHasCounters(selectedType!)) {
          for (int i = 0; i < ultralightCounterControllers.length; i++) {
            int counterValue =
                int.tryParse(ultralightCounterControllers[i].text) ?? 0;
            await appState.communicator!
                .mf0EmulatorSetCounterData(i, counterValue, true);
          }
        }
      }
    }

    await appState.communicator!
        .setSlotTagName(widget.slot, nameController.text, widget.frequency);
    await appState.communicator!.saveSlotData();

    widget.update(nameController.text, widget.frequency, selectedType);
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var appState = context.watch<ChameleonGUIState>();

    return AlertDialog(
      title: Text(localizations.edit_slot_data),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            children: [
              TextFormField(
                controller: nameController,
                validator: (value) => validateName(value, localizations),
              ),
              const SizedBox(height: 8),
              DropdownButton<TagType>(
                value: selectedType,
                items: [
                  ...getTagTypesByFrequency(widget.frequency),
                  TagType.unknown
                ].map<DropdownMenuItem<TagType>>((TagType type) {
                  return DropdownMenuItem<TagType>(
                    value: type,
                    child: Text(
                      chameleonTagToString(type, localizations),
                    ),
                  );
                }).toList(),
                onChanged: (TagType? newValue) {
                  if (newValue! != TagType.unknown) {
                    setState(() {
                      selectedType = newValue;
                      _mfkey32Configured = false;
                    });
                  }
                },
              ),
              if (widget.frequency == TagFrequency.hf) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<_SlotSetupMode>(
                  key: ValueKey(_setupMode),
                  initialValue: _setupMode,
                  decoration: InputDecoration(
                    labelText: _mfkey32Text.setupMode,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: _SlotSetupMode.manual,
                      child: Text(_mfkey32Text.manual),
                    ),
                    DropdownMenuItem(
                      value: _SlotSetupMode.mfkey32,
                      child: const Text('MFKEY32'),
                    ),
                  ],
                  onChanged: _configuringMfkey32
                      ? null
                      : (mode) async {
                          if (mode == null) return;
                          if (mode == _SlotSetupMode.mfkey32) {
                            await _configureMfkey32();
                          } else {
                            setState(() {
                              _setupMode = _SlotSetupMode.manual;
                              _mfkey32SetupError = null;
                            });
                          }
                        },
                ),
                if (_configuringMfkey32) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_mfkey32Text.readingAndConfiguring),
                ],
                if (_mfkey32SetupError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _mfkey32SetupError!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
              FutureBuilder(
                  future: updateInfo(),
                  builder: (BuildContext context, AsyncSnapshot snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting &&
                        !(previousTagType == selectedType ||
                            isMifareClassic(previousTagType) &&
                                isMifareClassic(selectedType!))) {
                      return const Column(
                          children: [CircularProgressIndicator()]);
                    } else if (snapshot.hasError) {
                      appState.connector!.performDisconnect();
                      return ErrorPage(errorMessage: snapshot.error.toString());
                    } else {
                      return Visibility(
                          visible: selectedType != TagType.unknown,
                          child: Column(children: [
                            Column(children: [
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: uidController,
                                decoration: InputDecoration(
                                    labelText: localizations.uid,
                                    hintText: localizations
                                        .enter_something(localizations.uid)),
                                inputFormatters: hexFormatter,
                                validator: (value) => validateUid(
                                    value,
                                    localizations,
                                    selectedType ?? widget.slotType),
                              ),
                              Visibility(
                                  visible: chameleonTagToFrequency(
                                          selectedType ?? widget.slotType) !=
                                      TagFrequency.lf,
                                  child: Column(
                                    children: [
                                      const SizedBox(height: 20),
                                      TextFormField(
                                        controller: sakController,
                                        decoration: InputDecoration(
                                            labelText: localizations.sak,
                                            hintText:
                                                localizations.enter_something(
                                                    localizations.sak)),
                                        inputFormatters: hexFormatter,
                                        validator: (value) =>
                                            chameleonTagToFrequency(
                                                        selectedType ??
                                                            widget.slotType) ==
                                                    TagFrequency.lf
                                                ? null
                                                : validateHex(
                                                    value, localizations,
                                                    exactBytes: 1,
                                                    fieldName:
                                                        localizations.sak,
                                                    required: true),
                                      ),
                                      const SizedBox(height: 20),
                                      TextFormField(
                                        controller: atqaController,
                                        decoration: InputDecoration(
                                            labelText: localizations.atqa,
                                            hintText:
                                                localizations.enter_something(
                                                    localizations.atqa)),
                                        inputFormatters: hexFormatter,
                                        validator: (value) =>
                                            chameleonTagToFrequency(
                                                        selectedType ??
                                                            widget.slotType) ==
                                                    TagFrequency.lf
                                                ? null
                                                : validateHex(
                                                    value, localizations,
                                                    exactBytes: 2,
                                                    fieldName:
                                                        localizations.atqa,
                                                    required: true),
                                      ),
                                      const SizedBox(height: 20),
                                      TextFormField(
                                          controller: atsController,
                                          decoration: InputDecoration(
                                              labelText: localizations.ats,
                                              hintText:
                                                  localizations.enter_something(
                                                      localizations.ats)),
                                          inputFormatters: hexFormatter,
                                          validator: (value) => validateHex(
                                              value, localizations)),
                                      if (isMifareUltralight(
                                          selectedType!)) ...[
                                        const SizedBox(height: 20),
                                        TextFormField(
                                            controller:
                                                ultralightVersionController,
                                            decoration: InputDecoration(
                                                labelText: localizations
                                                    .ultralight_version,
                                                hintText: localizations
                                                    .enter_something(localizations
                                                        .ultralight_version)),
                                            validator: (value) => validateHex(
                                                value, localizations)),
                                        const SizedBox(height: 20),
                                        TextFormField(
                                            controller:
                                                ultralightSignatureController,
                                            decoration: InputDecoration(
                                                labelText: localizations
                                                    .ultralight_signature,
                                                hintText: localizations
                                                    .enter_something(localizations
                                                        .ultralight_signature)),
                                            validator: (value) => validateHex(
                                                value, localizations)),
                                        if (mfUltralightHasCounters(
                                            selectedType!)) ...[
                                          const SizedBox(height: 20),
                                          ...ultralightCounterControllers
                                              .asMap()
                                              .entries
                                              .map((entry) {
                                            int index = entry.key;
                                            TextEditingController controller =
                                                entry.value;
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 10),
                                              child: TextFormField(
                                                controller: controller,
                                                decoration: InputDecoration(
                                                    labelText: localizations
                                                        .ultralight_counter(
                                                            index),
                                                    hintText: localizations
                                                        .ultralight_counter_value),
                                                validator: (value) =>
                                                    validateIntRange(
                                                        value, localizations,
                                                        min: 0,
                                                        max: 16777215,
                                                        emptyMessage: localizations
                                                            .counter_value_empty),
                                              ),
                                            );
                                          }),
                                        ],
                                      ],
                                      if (isMifareClassic(selectedType!) &&
                                          emulatorSettings != null)
                                        Column(children: [
                                          const SizedBox(height: 20),
                                          Text(
                                            localizations
                                                .mifare_classic_emulator_settings,
                                            textScaler:
                                                const TextScaler.linear(1.1),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen1a),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              key: ValueKey(emulatorSettings!
                                                  .isDetectionEnabled),
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen1a
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await appState.communicator!
                                                    .setMf1Gen1aMode(index == 0
                                                        ? true
                                                        : false);
                                              }),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen2),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen2
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await appState.communicator!
                                                    .setMf1Gen2Mode(index == 0
                                                        ? true
                                                        : false);
                                              }),
                                          const SizedBox(height: 8),
                                          Text(localizations.use_from_block),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isAntiColl
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await appState.communicator!
                                                    .setMf1UseFirstBlockColl(
                                                        index == 0
                                                            ? true
                                                            : false);
                                              }),
                                          const SizedBox(height: 8),
                                          Text(localizations
                                              .collect_nonces('Mfkey32')),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue: emulatorSettings!
                                                      .isDetectionEnabled
                                                  ? 0
                                                  : 1,
                                              onChange: (int index) async {
                                                final enabled = index == 0;
                                                await appState.communicator!
                                                    .setMf1DetectionStatus(
                                                        enabled);
                                                if (mounted) {
                                                  setState(() {
                                                    emulatorSettings!
                                                            .isDetectionEnabled =
                                                        enabled;
                                                    _setupMode = enabled
                                                        ? _SlotSetupMode.mfkey32
                                                        : _SlotSetupMode.manual;
                                                    if (!enabled) {
                                                      detectionCount = 0;
                                                    }
                                                  });
                                                }
                                              }),
                                          ...(emulatorSettings!
                                                  .isDetectionEnabled)
                                              ? [
                                                  if (detectionCount == 0) ...[
                                                    const SizedBox(height: 8),
                                                    Text(
                                                        localizations
                                                            .present_cham_reader_keys,
                                                        textScaler:
                                                            const TextScaler
                                                                .linear(0.8)),
                                                  ],
                                                  const SizedBox(height: 8),
                                                  Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      children: [
                                                        TextButton(
                                                            onPressed: () {
                                                              Navigator.pop(
                                                                  context);
                                                              Navigator.push(
                                                                context,
                                                                MaterialPageRoute(
                                                                  builder: (context) =>
                                                                      Mfkey32Menu(
                                                                          slot:
                                                                              widget.slot),
                                                                ),
                                                              );
                                                            },
                                                            child: Row(
                                                              children: [
                                                                const Icon(Icons
                                                                    .lock_open),
                                                                Text(localizations
                                                                    .recover_keys),
                                                              ],
                                                            )),
                                                      ]),
                                                ]
                                              : [
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      localizations
                                                          .ena_coll_recover_keys,
                                                      textScaler:
                                                          const TextScaler
                                                              .linear(0.8))
                                                ],
                                          const SizedBox(height: 8),
                                          Text(localizations.write_mode),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.normal,
                                                localizations.decline,
                                                localizations.deceive,
                                                localizations.shadow
                                              ],
                                              selectedValue: emulatorSettings!
                                                  .writeMode.value,
                                              onChange: (int index) async {
                                                if (index == 0) {
                                                  await appState.communicator!
                                                      .setMf1WriteMode(
                                                          MifareWriteMode
                                                              .normal);
                                                } else if (index == 1) {
                                                  await appState.communicator!
                                                      .setMf1WriteMode(
                                                          MifareWriteMode
                                                              .denied);
                                                } else if (index == 2) {
                                                  await appState.communicator!
                                                      .setMf1WriteMode(
                                                          MifareWriteMode
                                                              .deceive);
                                                } else if (index == 3) {
                                                  await appState.communicator!
                                                      .setMf1WriteMode(
                                                          MifareWriteMode
                                                              .shadow);
                                                }
                                              }),
                                        ]),
                                      if (isMifareUltralight(selectedType!) &&
                                          emulatorSettings != null)
                                        Column(children: [
                                          const SizedBox(height: 20),
                                          Text(
                                            localizations
                                                .mifare_ultralight_emulator_settings,
                                            textScaler:
                                                const TextScaler.linear(1.1),
                                          ),
                                          const SizedBox(height: 8),
                                          Text(localizations.mode_gen2),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue:
                                                  emulatorSettings!.isGen2
                                                      ? 0
                                                      : 1,
                                              onChange: (int index) async {
                                                await appState.communicator!
                                                    .mf0SetMagicMode(index == 0
                                                        ? true
                                                        : false);
                                              }),
                                          const SizedBox(height: 8),
                                          Text(
                                              localizations.password_detection),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.yes,
                                                localizations.no
                                              ],
                                              selectedValue: emulatorSettings!
                                                      .isDetectionEnabled
                                                  ? 0
                                                  : 1,
                                              onChange: (int index) async {
                                                await appState.communicator!
                                                    .mf0NtagSetDetectionEnable(
                                                        index == 0
                                                            ? true
                                                            : false);
                                              }),
                                          ...(emulatorSettings!
                                                  .isDetectionEnabled)
                                              ? [
                                                  ...(detectionCount == 0)
                                                      ? [
                                                          const SizedBox(
                                                              height: 8),
                                                          Text(
                                                              localizations
                                                                  .present_cham_reader_keys,
                                                              textScaler:
                                                                  const TextScaler
                                                                      .linear(
                                                                      0.8))
                                                        ]
                                                      : [
                                                          const SizedBox(
                                                              height: 8),
                                                          Text(
                                                              '${localizations.passwords_detected}: $detectionCount',
                                                              textScaler:
                                                                  const TextScaler
                                                                      .linear(
                                                                      0.9)),
                                                          const SizedBox(
                                                              height: 8),
                                                          Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .center,
                                                              children: [
                                                                TextButton(
                                                                    onPressed:
                                                                        () async {
                                                                      List<String>
                                                                          passwords =
                                                                          await appState
                                                                              .communicator!
                                                                              .mf0NtagGetDetectionLog(0);

                                                                      if (!context
                                                                          .mounted) {
                                                                        return;
                                                                      }

                                                                      showDialog(
                                                                        context:
                                                                            context,
                                                                        builder:
                                                                            (BuildContext
                                                                                context) {
                                                                          TextEditingController
                                                                              passwordController =
                                                                              TextEditingController();
                                                                          passwordController.text = passwords
                                                                              .join('\n')
                                                                              .toUpperCase();

                                                                          return AlertDialog(
                                                                            title:
                                                                                Text(localizations.detected_passwords),
                                                                            content:
                                                                                SizedBox(
                                                                              width: double.maxFinite,
                                                                              child: TextFormField(
                                                                                maxLines: null,
                                                                                controller: passwordController,
                                                                                readOnly: true,
                                                                                style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 16.0),
                                                                              ),
                                                                            ),
                                                                            actions: [
                                                                              TextButton(
                                                                                onPressed: () {
                                                                                  Navigator.of(context).pop();
                                                                                },
                                                                                child: Text(localizations.close),
                                                                              ),
                                                                            ],
                                                                          );
                                                                        },
                                                                      );
                                                                    },
                                                                    child: Row(
                                                                      children: [
                                                                        const Icon(
                                                                            Icons.visibility),
                                                                        Text(localizations
                                                                            .view_passwords),
                                                                      ],
                                                                    )),
                                                              ]),
                                                        ],
                                                ]
                                              : [
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      localizations
                                                          .enable_password_detection,
                                                      textScaler:
                                                          const TextScaler
                                                              .linear(0.8))
                                                ],
                                          const SizedBox(height: 8),
                                          Text(localizations.write_mode),
                                          const SizedBox(height: 8),
                                          ToggleButtonsWrapper(
                                              items: [
                                                localizations.normal,
                                                localizations.decline,
                                                localizations.deceive,
                                                localizations.shadow
                                              ],
                                              selectedValue: emulatorSettings!
                                                  .writeMode.value,
                                              onChange: (int index) async {
                                                if (index == 0) {
                                                  await appState.communicator!
                                                      .mf0NtagSetWriteMode(
                                                          MifareWriteMode
                                                              .normal);
                                                } else if (index == 1) {
                                                  await appState.communicator!
                                                      .mf0NtagSetWriteMode(
                                                          MifareWriteMode
                                                              .denied);
                                                } else if (index == 2) {
                                                  await appState.communicator!
                                                      .mf0NtagSetWriteMode(
                                                          MifareWriteMode
                                                              .deceive);
                                                } else if (index == 3) {
                                                  await appState.communicator!
                                                      .mf0NtagSetWriteMode(
                                                          MifareWriteMode
                                                              .shadow);
                                                }
                                              }),
                                        ]),
                                    ],
                                  )),
                            ]),
                            if (selectedType == TagType.hidProx)
                              Column(children: [
                                const SizedBox(height: 20),
                                DropdownButton<int>(
                                  value:
                                      int.tryParse(hidTypeController.text) ?? 1,
                                  items: List.generate(30, (index) => index + 1)
                                      .map<DropdownMenuItem<int>>((int type) {
                                    return DropdownMenuItem<int>(
                                      value: type,
                                      child: Text(getNameForHIDProxType(type)),
                                    );
                                  }).toList(),
                                  onChanged: (int? newValue) {
                                    if (newValue != null) {
                                      setState(() {
                                        hidTypeController.text =
                                            newValue.toString();
                                      });
                                    }
                                  },
                                  isExpanded: true,
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: facilityCodeController,
                                  decoration: InputDecoration(
                                      labelText: localizations.facility_code,
                                      hintText: localizations.enter_something(
                                          localizations.facility_code)),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 4294967295),
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: issueLevelController,
                                  decoration: InputDecoration(
                                      labelText: localizations.issue_level,
                                      hintText: localizations.enter_something(
                                          localizations.issue_level)),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 255),
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: oemController,
                                  decoration: InputDecoration(
                                      labelText: "OEM",
                                      hintText:
                                          localizations.enter_something('OEM')),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  validator: (value) => validateIntRange(
                                      value, localizations,
                                      min: 0, max: 65535),
                                ),
                              ])
                          ]));
                    }
                  })
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(localizations.cancel),
        ),
        TextButton(
          onPressed: () async {
            if (!_formKey.currentState!.validate()) {
              return;
            }

            await save();

            if (context.mounted) {
              Navigator.pop(context);
            }
          },
          child: Text(localizations.save),
        ),
      ],
    );
  }
}

class _Mfkey32SlotText {
  final bool italian;

  const _Mfkey32SlotText(this.italian);

  String get setupMode => italian ? 'Configurazione' : 'Configuration';
  String get manual => italian ? 'Manuale' : 'Manual';
  String get setupTitle =>
      italian ? 'Configurazione automatica MFKEY32' : 'Automatic MFKEY32 setup';
  String get presentOriginalCard => italian
      ? 'Avvicina ora la carta originale al Chameleon. Verranno letti UID, SAK, ATQA e ATS; lo slot sarà configurato come MIFARE Classic e la raccolta nonce sarà attivata.'
      : 'Present the original card to Chameleon now. UID, SAK, ATQA and ATS will be read; the slot will be configured as MIFARE Classic and nonce collection will be enabled.';
  String get cancel => italian ? 'Annulla' : 'Cancel';
  String get readAndConfigure =>
      italian ? 'Leggi e configura' : 'Read and configure';
  String get readingAndConfiguring => italian
      ? 'Lettura della carta e configurazione dello slot…'
      : 'Reading the card and configuring the slot…';
  String get noCardFound => italian
      ? 'Nessuna carta rilevata. Avvicina la carta originale e riprova.'
      : 'No card detected. Present the original card and try again.';
  String get notMifareClassic => italian
      ? 'La carta rilevata non è una MIFARE Classic.'
      : 'The detected card is not MIFARE Classic.';
  String get unsupportedClassic => italian
      ? 'Tipo MIFARE Classic non supportato dallo slot.'
      : 'MIFARE Classic type is not supported by the slot.';
}
