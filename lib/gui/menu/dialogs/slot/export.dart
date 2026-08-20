import 'dart:convert';
import 'dart:io';

import 'package:chameleonultragui/gui/component/card_list.dart';
import 'package:chameleonultragui/gui/component/toggle_buttons.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/slot_card_sync.dart';
import 'package:flutter/material.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:provider/provider.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class SlotExportMenu extends StatefulWidget {
  final SlotNames names;
  final EnabledSlotInfo enabledSlotInfo;
  final SlotTypes slotTypes;

  const SlotExportMenu(
      {super.key,
      required this.names,
      required this.enabledSlotInfo,
      required this.slotTypes});

  @override
  SlotExportMenuState createState() => SlotExportMenuState();
}

class SlotExportMenuState extends State<SlotExportMenu> {
  TagFrequency exportFrequency = TagFrequency.unknown;

  Future<CardSave?> rebuildCardSaveFromSlot(TagFrequency frequency) async {
    final appState = context.read<ChameleonGUIState>();
    return readCardSaveFromActiveSlot(
      communicator: appState.communicator!,
      tag: frequency == TagFrequency.hf
          ? widget.slotTypes.hf
          : widget.slotTypes.lf,
      frequency: frequency,
      name: frequency == TagFrequency.hf ? widget.names.hf : widget.names.lf,
    );
  }

  Future<void> onTap(
      CardSave card, dynamic close, AppLocalizations localizations) async {
    var appState = Provider.of<ChameleonGUIState>(context, listen: false);
    close(context, card.name);

    CardSave modify = card;
    CardSave? newCard =
        await rebuildCardSaveFromSlot(chameleonTagToFrequency(card.tag));

    if (newCard == null) {
      return;
    }

    // modify only changeable values
    modify.uid = newCard.uid;
    modify.tag = newCard.tag;
    modify.sak = newCard.sak;
    modify.atqa = newCard.atqa;
    modify.ats = newCard.ats;
    modify.data = newCard.data;

    var tags = appState.sharedPreferencesProvider.getCards();
    var index = tags.indexWhere((element) => element.id == modify.id);

    if (index != -1) {
      tags[index] = modify;
    }

    appState.sharedPreferencesProvider.setCards(tags);

    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    var appState = context.watch<ChameleonGUIState>();

    List<String> buttons = [];
    if (widget.slotTypes.hf != TagType.unknown) {
      buttons.add(localizations.hf);
    }

    if (widget.slotTypes.lf != TagType.unknown) {
      buttons.add(localizations.lf);
    }

    if (exportFrequency == TagFrequency.unknown) {
      setState(() {
        exportFrequency =
            buttons[0] == localizations.hf ? TagFrequency.hf : TagFrequency.lf;
      });
    }

    return AlertDialog(
      title: Text(localizations.export_slot_data),
      content: SingleChildScrollView(
          child: Column(
        children: [
          Text(localizations.frequency_to_export),
          const SizedBox(height: 8),
          ToggleButtonsWrapper(
              items: buttons,
              selectedValue: 0,
              onChange: (int index) async {
                setState(() {
                  exportFrequency = buttons[index] == localizations.hf
                      ? TagFrequency.hf
                      : TagFrequency.lf;
                });
              }),
        ],
      )),
      actions: [
        ElevatedButton(
          onPressed: () async {
            CardSave? cardSave = await rebuildCardSaveFromSlot(exportFrequency);

            if (cardSave == null) {
              return;
            }

            Uint8List export = const Utf8Encoder().convert(cardSave.toJson());
            try {
              await FileSaver.instance.saveAs(
                  name: cardSave.name,
                  bytes: export,
                  ext: 'json',
                  mimeType: MimeType.json);
            } on UnimplementedError catch (_) {
              String? outputFile = await FilePicker.platform.saveFile(
                dialogTitle: '${localizations.output_file}:',
                fileName: '${cardSave.name}.json',
              );

              if (outputFile != null) {
                var file = File(outputFile);
                await file.writeAsBytes(export);
              }
            }
            if (context.mounted) {
              Navigator.pop(context);
            }
          },
          child: Text(localizations.save_to_file),
        ),
        ElevatedButton(
          onPressed: () async {
            CardSave? tag = await rebuildCardSaveFromSlot(exportFrequency);
            if (context.mounted && tag != null) {
              await showDialog(
                context: context,
                builder: (BuildContext dialogContext) {
                  TextEditingController controller =
                      TextEditingController(text: tag.name);
                  return AlertDialog(
                    title: Text(localizations.enter_name_of_card),
                    content: TextField(controller: controller),
                    actions: [
                      ElevatedButton(
                        onPressed: () async {
                          tag.name = controller.text;
                          var tags =
                              appState.sharedPreferencesProvider.getCards();
                          tags.add(tag);
                          appState.sharedPreferencesProvider.setCards(tags);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                            Navigator.pop(context);
                          }
                        },
                        child: Text(localizations.ok),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                        },
                        child: Text(localizations.cancel),
                      ),
                    ],
                  );
                },
              );
            }
          },
          child: Text(localizations.export_to_new_card),
        ),
        ElevatedButton(
          onPressed: () async {
            var appState = context.read<ChameleonGUIState>();
            var tags = appState.sharedPreferencesProvider.getCards();

            tags.sort((a, b) => a.name.compareTo(b.name));

            showSearch<String>(
              context: context,
              delegate: CardSearchDelegate(
                  cards: tags,
                  onTap: onTap,
                  filter: exportFrequency == TagFrequency.hf
                      ? SearchFilter.hf
                      : SearchFilter.lf),
            );
          },
          child: Text(localizations.update_saved_card),
        ),
      ],
    );
  }
}
